{
    Provable-receiver devirtualization (-OoDEVIRT)

    Intra-procedural counterpart of the fork's WPO devirtualization pass
    (-Owdevirtcalls, compiler/optvirt.pas + wpo*.pas). Where the WPO pass needs
    a whole-program feedback file to prove a virtual call monomorphic, this pass
    proves it inside a single routine from constructor provenance, needing no
    feedback file, and rewrites the indirect VMT dispatch into a direct call.

    Transform

        l := TFoo.Create;         // concrete constructor, class TFoo
        ...
        l.VirtMethod(args);       // virtual dispatch on l

    becomes a direct call to TFoo's resolution of VirtMethod's vmt slot (the
    override the runtime dispatch would have selected). The receiver l is still
    loaded and passed as self; only the dispatch changes: no VMT indirect load.
    Being a direct call, the target additionally becomes a candidate for the
    ordinary inliner (see the note in psub.TransformNodeTree).

    Soundness (correctness over coverage -- a wrong target is a miscompile):

      * The receiver must be a plain LOCAL variable or by-value PARAMETER
        reference (loadn of a localvarsym/paravarsym).
      * EVERY assignment to that variable in the routine must be a concrete
        constructor call  TSpecific.Create  -- a loadvmtaddr of a typen, i.e. a
        named class, never a class-reference (TClass) variable which proves
        nothing -- and they must all construct the SAME class TFoo. Then the
        only non-nil value the variable can hold is a TFoo instance, so every
        virtual call on it dispatches into TFoo's vmt regardless of control
        flow. (Calling a virtual method on nil is already undefined in the
        indirect form -- it faults on the VMT load -- so requiring no nil guard
        matches the WPO pass.)
      * The variable must NOT be address-taken (@v), captured by a nested scope
        (different_scope), or passed by var/out anywhere: any of those could
        rebind it to an object of a different type. Passing it by value or by
        const(ref) does NOT change the reference and is safe.
      * The CONSTRUCTED class is used, not the variable's declared type: a
        variable declared TBase but built as TFoo dispatches as TFoo. The
        constructed class must be a class (is_class) related to the call site's
        static receiver type, so the base method's vmt index selects the correct
        slot in the constructed class's vmt.
      * Interfaces, virtual class methods/constructors called via an instance,
        and dynamic casts are skipped (they prove only upper bounds or use a
        different dispatch table).

    The resolved override keeps the base procdef's signature (it overrides it),
    so procdefinition -- used by codegen for the call convention and parameter
    layout -- is left untouched and only the emitted symbol name is forced, via
    tcallnode.devirtualize_target, exactly like the WPO name substitution.

    Opt-in via -OoDEVIRT; NOT part of the -O4 defaults.

    This module is free software; see the FPC copying conditions.
}
unit optdevirt;

{$i fpcdefs.inc}

interface

    uses
      node;

    { rewrite provably-monomorphic virtual calls in the routine tree CODE into
      direct calls to the constructed class's concrete override }
    procedure OptimizeDevirt(var code : tnode);

implementation

    uses
      globtype,cutils,
      symconst,symtype,symsym,symdef,
      defcmp,
      nutils,nld,ncal,ncnv,nmem,
      optutils;

    const
      PASSNAME = 'devirt';

    type
      tdevirtsym = record
        sym      : tsym;
        cls      : tobjectdef;   { the single constructed class, nil until first ctor def }
        haddef   : boolean;      { at least one assignment seen }
        poisoned : boolean;      { non-ctor def, differing ctor class, byref/addr use }
      end;

      pdevirtctx = ^tdevirtctx;
      tdevirtctx = record
        syms    : array of tdevirtsym;
        count   : integer;
        applied : longint;
      end;


    { human-readable "TFoo.Bar" name for a method procdef, for -Ooreport }
    function methodname(pd : tabstractprocdef) : string;
      begin
        if (pd.typ=procdef) and assigned(tprocdef(pd).struct) and
           assigned(tprocdef(pd).procsym) then
          result:=tprocdef(pd).struct.typesymbolprettyname+'.'+
                   tprocdef(pd).procsym.realname
        else
          result:=pd.typesymbolprettyname;
      end;


    { strip surrounding type conversions to reach the payload node }
    function strip_conv(n : tnode) : tnode;
      begin
        while assigned(n) and (n.nodetype=typeconvn) do
          n:=ttypeconvnode(n).left;
        result:=n;
      end;


    { if N (ignoring type conversions) is a load of a local var / by-value
      parameter, return its symbol, else nil }
    function receiver_sym(n : tnode) : tsym;
      begin
        result:=nil;
        n:=strip_conv(n);
        if assigned(n) and (n.nodetype=loadn) and
           assigned(tloadnode(n).symtableentry) and
           (tloadnode(n).symtableentry.typ in [localvarsym,paravarsym]) then
          result:=tloadnode(n).symtableentry;
      end;


    { if N (ignoring type conversions) is a concrete constructor call
      TFoo.Create -- a loadvmtaddr over a typen, NOT a class-reference variable
      -- return the constructed class TFoo, else nil }
    function ctor_class(n : tnode) : tobjectdef;
      var
        cn : tcallnode;
        mp : tnode;
      begin
        result:=nil;
        n:=strip_conv(n);
        if not(assigned(n) and (n.nodetype=calln)) then
          exit;
        cn:=tcallnode(n);
        if not assigned(cn.procdefinition) or
           (cn.procdefinition.typ<>procdef) or
           (cn.procdefinition.proctypeoption<>potype_constructor) then
          exit;
        mp:=cn.methodpointer;
        if not(assigned(mp) and (mp.nodetype=loadvmtaddrn)) then
          exit;
        { TFoo.Create has a typen under the loadvmtaddr; a class-ref variable
          has a load there instead and proves nothing }
        if tloadvmtaddrnode(mp).left.nodetype<>typen then
          exit;
        if not(assigned(mp.resultdef) and (mp.resultdef.typ=classrefdef)) then
          exit;
        if is_class(tclassrefdef(mp.resultdef).pointeddef) then
          result:=tobjectdef(tclassrefdef(mp.resultdef).pointeddef);
      end;


    { find (or create) the tracking slot for SYM }
    function getslot(ctx : pdevirtctx; sym : tsym) : integer;
      var
        i : integer;
      begin
        for i:=0 to ctx^.count-1 do
          if ctx^.syms[i].sym=sym then
            exit(i);
        if ctx^.count>=length(ctx^.syms) then
          setlength(ctx^.syms,length(ctx^.syms)*2+8);
        result:=ctx^.count;
        inc(ctx^.count);
        ctx^.syms[result].sym:=sym;
        ctx^.syms[result].cls:=nil;
        ctx^.syms[result].haddef:=false;
        ctx^.syms[result].poisoned:=false;
      end;


    procedure poison(ctx : pdevirtctx; sym : tsym);
      var
        idx : integer;
      begin
        if assigned(sym) then
          begin
            { getslot may reallocate ctx^.syms, so resolve the index BEFORE
              indexing the array }
            idx:=getslot(ctx,sym);
            ctx^.syms[idx].poisoned:=true;
          end;
      end;


    { collect, for every tracked local, whether all its definitions are the
      same concrete constructor and whether anything unsafe happens to it }
    function scan_defs(var n : tnode; arg : pointer) : foreachnoderesult;
      var
        ctx : pdevirtctx;
        sym : tsym;
        cls : tobjectdef;
        cp  : tcallparanode;
        idx : integer;
      begin
        result:=fen_false;
        ctx:=pdevirtctx(arg);
        case n.nodetype of
          assignn:
            begin
              sym:=receiver_sym(tassignmentnode(n).left);
              if assigned(sym) then
                begin
                  idx:=getslot(ctx,sym);
                  cls:=ctor_class(tassignmentnode(n).right);
                  if not assigned(cls) then
                    { assigned something that is not a concrete constructor }
                    ctx^.syms[idx].poisoned:=true
                  else if not ctx^.syms[idx].haddef then
                    begin
                      ctx^.syms[idx].cls:=cls;
                      ctx^.syms[idx].haddef:=true;
                    end
                  else if ctx^.syms[idx].cls<>cls then
                    ctx^.syms[idx].poisoned:=true;
                end;
            end;
          addrn:
            poison(ctx,receiver_sym(taddrnode(n).left));
          calln:
            begin
              { by-var / by-out arguments can rebind the reference }
              cp:=tcallparanode(tcallnode(n).left);
              while assigned(cp) do
                begin
                  if assigned(cp.parasym) and
                     (cp.parasym.varspez in [vs_var,vs_out]) then
                    poison(ctx,receiver_sym(cp.left));
                  cp:=tcallparanode(cp.right);
                end;
            end;
        end;
      end;


    { is CN a virtual method call on an instance whose receiver is a plain
      local-variable load (the shape -OoDEVIRT can act on)? }
    function is_devirt_candidate(cn : tcallnode) : boolean;
      begin
        result:=
          assigned(cn.procdefinition) and
          (cn.procdefinition.typ=procdef) and
          (cn.right=nil) and
          not cn.has_forced_call_name and
          not(cnf_inherited in cn.callnodeflags) and
          (po_virtualmethod in cn.procdefinition.procoptions) and
          not(cn.procdefinition.proctypeoption in [potype_constructor,potype_destructor]) and
          assigned(cn.methodpointer) and
          (cn.methodpointer.nodetype=loadn) and
          assigned(tprocdef(cn.procdefinition).struct) and
          not is_objectpascal_helper(tprocdef(cn.procdefinition).struct) and
          assigned(cn.methodpointer.resultdef) and
          is_class(cn.methodpointer.resultdef);
      end;


    function apply_devirt(var n : tnode; arg : pointer) : foreachnoderesult;
      var
        ctx    : pdevirtctx;
        cn     : tcallnode;
        sym    : tsym;
        idx    : integer;
        i      : integer;
        cls    : tobjectdef;
        vmtidx : longint;
        target : tprocdef;
      begin
        result:=fen_false;
        ctx:=pdevirtctx(arg);
        if n.nodetype<>calln then
          exit;
        cn:=tcallnode(n);
        if not is_devirt_candidate(cn) then
          exit;

        sym:=tloadnode(cn.methodpointer).symtableentry;
        idx:=-1;
        for i:=0 to ctx^.count-1 do
          if ctx^.syms[i].sym=sym then
            begin idx:=i; break; end;

        if (idx<0) or not ctx^.syms[idx].haddef then
          begin
            OptRemark(cn.fileinfo,PASSNAME,
              'call to '+methodname(cn.procdefinition)+
              ' not devirtualized (receiver type not provable: no local constructor)');
            exit;
          end;

        if ctx^.syms[idx].poisoned then
          begin
            OptRemark(cn.fileinfo,PASSNAME,
              'call to '+methodname(cn.procdefinition)+
              ' not devirtualized (receiver reassigned / address-taken / passed by reference)');
            exit;
          end;

        { extra safety: reject variables the front end flagged as escaping }
        if tabstractvarsym(sym).addr_taken or
           tabstractvarsym(sym).different_scope then
          begin
            OptRemark(cn.fileinfo,PASSNAME,
              'call to '+methodname(cn.procdefinition)+
              ' not devirtualized (receiver escapes: address-taken or captured)');
            exit;
          end;

        cls:=ctx^.syms[idx].cls;

        { the constructed class must derive from (or equal) the call's static
          receiver type, so the base method's vmt index selects the right slot }
        if not def_is_related(cls,cn.methodpointer.resultdef) then
          begin
            OptRemark(cn.fileinfo,PASSNAME,
              'call to '+methodname(cn.procdefinition)+
              ' not devirtualized (constructed type unrelated to receiver type)');
            exit;
          end;

        vmtidx:=tprocdef(cn.procdefinition).extnumber;
        if (vmtidx=$ffff) or (vmtidx<0) or (vmtidx>=cls.vmtentries.count) then
          begin
            OptRemark(cn.fileinfo,PASSNAME,
              'call to '+methodname(cn.procdefinition)+
              ' not devirtualized (no vmt slot in constructed class)');
            exit;
          end;

        target:=pvmtentry(cls.vmtentries[vmtidx])^.procdef;
        if not assigned(target) or
           (po_abstractmethod in target.procoptions) or
           not target.is_implemented then
          begin
            OptRemark(cn.fileinfo,PASSNAME,
              'call to '+methodname(cn.procdefinition)+
              ' not devirtualized (target abstract or not implemented)');
            exit;
          end;

        cn.devirtualize_target(target);
        inc(ctx^.applied);
        OptRemark(cn.fileinfo,PASSNAME,
          'call to '+methodname(target)+
          ' devirtualized (receiver constructed as '+cls.typesymbolprettyname+')');
      end;


    procedure OptimizeDevirt(var code : tnode);
      var
        ctx : tdevirtctx;
      begin
        if not assigned(code) then
          exit;
        ctx.count:=0;
        ctx.applied:=0;
        setlength(ctx.syms,0);
        { pass 1: gather constructor provenance / poison facts }
        foreachnodestatic(pm_postprocess,code,@scan_defs,@ctx);
        { pass 2: rewrite provable call sites }
        foreachnodestatic(pm_postprocess,code,@apply_devirt,@ctx);
        setlength(ctx.syms,0);
      end;

end.
