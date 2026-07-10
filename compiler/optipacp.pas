{
    Interprocedural constant propagation via function cloning (-OoIPACP)

    Ports the idea of gcc's -fipa-cp / -fipa-cp-clone passes to FPC.

    FPC is single-pass with immediate code generation: an ordinary unit-level
    routine is parsed AND fully code-generated the moment its body is read
    (read_proc_body -> generate_code_tree), then its node tree is freed.  There
    is therefore no phase in which a whole unit's routine bodies coexist as
    trees, so gcc's "inject the constant into the one shared callee body" model
    is impossible here -- callees are always compiled before their callers, so
    a constant fact discovered at a call site can never flow backward into an
    already-generated body.

    The only forward-viable design (and the one implemented here) is a
    call-site-driven CLONE, mirroring -OoPARTIALINLINE:

      * When an eligible routine's body has just been parsed and type-checked
        -- but BEFORE it is first-passed and code-generated -- a deep copy of
        that (type-checked, not-yet-lowered) body is stashed as a template,
        together with the set of its parameters that may be specialized
        (ipacp_stash_candidate).

      * When a LATER caller passes a compile-time ordinal/boolean/enum constant
        for one of those eligible by-value, never-written parameters, a fresh
        out-of-line CLONE procdef is synthesised (ipacp_process_calls):
          - a private procdef alias is created (create_procdef_alias) with the
            SAME signature as the original, so the calling convention is
            untouched (the constant argument is still passed, just ignored in
            the body);
          - the stashed template is copied, its parameter/local/funcret loads
            are remapped onto the clone's own parast/localst, and every read of
            the specialized parameter is replaced by the literal;
          - the caller's call node is retargeted by rebuilding a fresh call to
            the clone's procsym (a clean re-typecheck -- we never repoint the
            already-bound procdefinition of the existing call, which would leave
            its callparanode.parasym pointers dangling on the original parast).

      * The clone body is stashed at PRE-firstpass time, so when the clone is
        finally compiled (compile_ipacp_clone in psub) its own do_firstpass runs
        fresh over the substituted constants -- constant folding and dead-branch
        elimination fire naturally (an `if N=3` with N:=3 collapses to its taken
        arm), and the loop passes then see now-constant loop bounds.  No manual
        re-fold is needed because the template was never first-passed.

    Clones are cached per (routine, parameter, value) and shared across all call
    sites in the unit; a stashed template is reused for every clone of the same
    routine.  Growth is bounded by a node-count budget on the callee body, a
    per-routine clone cap, and a per-module clone cap.

    Correctness notes:
      - the ORIGINAL routine is never modified, so any call site we do not touch
        (variable argument, budget exceeded, ineligible) keeps the general body;
      - only a genuine constant node is dropped into the body, so no
        side-effecting argument expression is ever elided; the constant argument
        is still evaluated (and ignored) at the call, preserving evaluation
        order and the side effects of the OTHER arguments;
      - a parameter is specialized only if it is a by-value/const ordinal that
        the body never writes (checked via varstate AND a structural scan for
        assignment/address-of/var-out passing), so substituting the literal is
        observably identical;
      - a clone that calls the original routine recursively is sound (we do not
        clone recursion, we just retarget the leaf constant call);
      - bodies with exception handling, inline assembler, labels/gotos, nested
        routines, or non-plain-local locals are rejected, keeping the remap
        total and the re-typecheck clean.

    Opt-in via -OoIPACP (NOT part of -O4 defaults).  Intra-unit only: the stash
    is per-module, so cross-unit specialization is out of scope.

    This module is free software; see the FPC copying conditions.
}
unit optipacp;

{$i fpcdefs.inc}

interface

    uses
      cclasses,
      globtype,node,symdef;

    { Reset the per-module stash and clone cache.  Cheap to call; only clears
      when the module actually changed. }
    procedure ipacp_module_check;

    { If PD is an eligible clone target, stash a deep copy of its type-checked
      (not-yet-first-passed) body CODE as a template for later callers.  Must be
      called on the final node tree BEFORE generate_code_tree lowers/frees it. }
    procedure ipacp_stash_candidate(pd : tprocdef; code : tnode;
      piflags : tprocinfoflags; hasnested : boolean);

    { Scan CALLERPD's type-checked (not-yet-first-passed) body CODE for direct
      calls that pass a compile-time constant to an eligible parameter of a
      stashed routine.  For each, get-or-create a specialized clone and retarget
      the call.  Newly-created clones are appended to PENDING (each a
      tipacpclone carrying the clone procdef and its still-uncompiled body); the
      caller (psub) compiles them after its own generate_code_tree. }
    procedure ipacp_process_calls(callerpd : tprocdef; var code : tnode;
      pending : TFPObjectList);

    type
      { a clone whose body has been synthesised but not yet code-generated }
      tipacpclone = class
        clonepd   : tprocdef;
        clonecode : tnode;
        constructor create(apd : tprocdef; acode : tnode);
      end;

implementation

    uses
      globals,cutils,constexp,verbose,fmodule,
      symconst,symbase,symtype,symsym,symtable,
      defutil,paramgr,pparautl,pass_1,
      nbas,nld,nmem,ncal,ncon,nutils,
      optutils,
      symcreat;

    const
      { do not clone a callee whose body exceeds this many nodes }
      ipacp_body_budget = 400;
      { at most this many distinct clones per original routine }
      ipacp_clones_per_routine = 4;
      { at most this many clones per module (bounds total code growth) }
      ipacp_clones_per_module = 64;

    { ---- per-module state --------------------------------------------------- }

    type
      tipacpstash = class
        calleepd     : tprocdef;
        bodytemplate : tnode;        { deep copy: typechecked, NOT firstpassed }
        eligibleparas : array of longint;  { visible indices of substitutable params }
        destructor destroy; override;
      end;

    var
      cur_module    : pointer = nil;       { tmodule the state belongs to }
      stashlist     : TFPObjectList = nil; { of tipacpstash, keyed linearly }
      clonecache    : TFPHashList = nil;   { clone key -> clone tprocdef }
      module_clones : longint = 0;

    constructor tipacpclone.create(apd : tprocdef; acode : tnode);
      begin
        clonepd:=apd;
        clonecode:=acode;
      end;

    destructor tipacpstash.destroy;
      begin
        if assigned(bodytemplate) then
          bodytemplate.free;
        inherited destroy;
      end;

    procedure ipacp_clear;
      begin
        if assigned(stashlist) then
          begin
            stashlist.free;
            stashlist:=nil;
          end;
        if assigned(clonecache) then
          begin
            clonecache.free;
            clonecache:=nil;
          end;
        module_clones:=0;
      end;

    procedure ipacp_module_check;
      begin
        if cur_module<>pointer(current_module) then
          begin
            ipacp_clear;
            cur_module:=pointer(current_module);
            stashlist:=TFPObjectList.create(true);
            clonecache:=TFPHashList.create;
          end;
      end;

    { ---- eligibility -------------------------------------------------------- }

    { the whole body must be free of exception handling, inline assembler,
      labels and gotos (as in optpartialinline: these procinfo flags are only
      set during firstpass, which has not run yet, so scan the tree directly) }
    function scan_body_unsafe(var n : tnode; arg : pointer) : foreachnoderesult;
      begin
        result:=fen_true;
        case n.nodetype of
          asmn,tryexceptn,tryfinallyn,onn,labeln,goton,raisen:
            begin
              pboolean(arg)^:=false;
              result:=fen_norecurse_true;
            end;
          else
            ;
        end;
      end;

    function body_is_safe(code : tnode) : boolean;
      begin
        result:=true;
        foreachnodestatic(pm_postprocess,code,@scan_body_unsafe,@result);
      end;

    { the clone's localst is a straight copy of the callee's; only plain local
      variables (plus the single funcret local) may appear -- anything else
      (typed constants / static vars / labels / absolute vars) would need extra
      remapping we do not do, so reject such a routine }
    function localst_is_simple(pd : tprocdef) : boolean;
      var
        i : longint;
        sym : tsym;
      begin
        result:=false;
        if not assigned(pd.localst) then
          exit;
        if pd.localst.symtabletype<>localsymtable then
          exit;
        for i:=0 to pd.localst.symlist.count-1 do
          begin
            sym:=tsym(pd.localst.symlist[i]);
            { the funcret local and its name/RESULT aliases (all flagged
              vo_is_funcret) are rebuilt for the clone by insert_funcret_local
              and remapped structurally; plain locals are copied. Anything else
              (user `absolute` vars, typed constants, labels) is rejected. }
            if (sym is tabstractvarsym) and
               (vo_is_funcret in tabstractvarsym(sym).varoptions) then
              continue;
            if sym.typ<>localvarsym then
              exit;
          end;
        result:=true;
      end;

    function proc_eligible(pd : tprocdef) : boolean;
      begin
        result:=false;
        if not(pd.proctypeoption in [potype_procedure,potype_function]) then
          exit;
        { only a register-returned (or void) result: a result returned via a
          hidden pointer parameter (managed/large types) needs funcret handling
          we do not replicate -- skip it }
        if not is_void(pd.returndef) and
           paramanager.ret_in_param(pd.returndef,pd) then
          exit;
        if assigned(pd.struct) then
          exit;
        if pd.owner.symtabletype<>staticsymtable then
          exit;
        if pd.parast.symtablelevel>normal_function_level then
          exit;
        if [df_generic,df_specialization]*pd.defoptions<>[] then
          exit;
        if ([po_external,po_virtualmethod,po_abstractmethod,po_assembler,
             po_exports,po_interrupt,po_inline,po_noinline,
             po_classmethod,po_varargs]*pd.procoptions)<>[] then
          exit;
        if not assigned(pd.procsym) or (pd.procsym.typ<>procsym) then
          exit;
        { a separate forward/interface declaration means earlier-parsed call
          sites and (for interface routines) external units bind this name }
        if tprocsym(pd.procsym).ProcdefList.Count<>1 then
          exit;
        if pd.interfacedef then
          exit;
        result:=true;
      end;

    { visible-index of paravarsym SYM within PD, or -1 }
    function visible_index_of(pd : tprocdef; sym : tsym) : longint;
      var
        i,vis : longint;
        pv : tparavarsym;
      begin
        result:=-1;
        vis:=0;
        for i:=0 to pd.paras.count-1 do
          begin
            pv:=tparavarsym(pd.paras[i]);
            if vo_is_hidden_para in pv.varoptions then
              continue;
            if tsym(pv)=sym then
              exit(vis);
            inc(vis);
          end;
      end;

    { find the visible (non-hidden) parameter of PD at visible-index IDX }
    function nth_visible_para(pd : tprocdef; idx : longint) : tparavarsym;
      var
        i,vis : longint;
        pv : tparavarsym;
      begin
        result:=nil;
        vis:=0;
        for i:=0 to pd.paras.count-1 do
          begin
            pv:=tparavarsym(pd.paras[i]);
            if vo_is_hidden_para in pv.varoptions then
              continue;
            if vis=idx then
              exit(pv);
            inc(vis);
          end;
      end;

    { -------- per-parameter write-safety scan ------------------------------- }

    type
      pwritescan = ^twritescan;
      twritescan = record
        target : tsym;   { the paravarsym we want to substitute }
        safe   : boolean;
      end;

    { reject substitution if the parameter is ever written: it appears as the
      target of an assignment, has its address taken, or is passed to a
      var/out/constref formal parameter of another call }
    function scan_param_write(var n : tnode; arg : pointer) : foreachnoderesult;
      var
        ctx : pwritescan;
        pn  : tcallparanode;
      begin
        result:=fen_true;
        ctx:=pwritescan(arg);
        case n.nodetype of
          assignn:
            if (tassignmentnode(n).left.nodetype=loadn) and
               (tloadnode(tassignmentnode(n).left).symtableentry=ctx^.target) then
              ctx^.safe:=false;
          addrn:
            if (taddrnode(n).left.nodetype=loadn) and
               (tloadnode(taddrnode(n).left).symtableentry=ctx^.target) then
              ctx^.safe:=false;
          callparan:
            begin
              pn:=tcallparanode(n);
              if assigned(pn.parasym) and
                 (pn.parasym.varspez in [vs_var,vs_out,vs_constref]) and
                 assigned(pn.left) and (pn.left.nodetype=loadn) and
                 (tloadnode(pn.left).symtableentry=ctx^.target) then
                ctx^.safe:=false;
            end;
          else
            ;
        end;
        if not ctx^.safe then
          result:=fen_norecurse_true;
      end;

    function param_readonly(pv : tparavarsym; code : tnode) : boolean;
      var
        ctx : twritescan;
      begin
        result:=false;
        { const parameters are guaranteed read-only by the language;
          value parameters must not have been written }
        if pv.varspez=vs_value then
          begin
            if pv.varstate in [vs_written,vs_readwritten] then
              exit;
          end
        else if pv.varspez<>vs_const then
          exit;
        ctx.target:=pv;
        ctx.safe:=true;
        foreachnodestatic(pm_postprocess,code,@scan_param_write,@ctx);
        result:=ctx.safe;
      end;

    { a specializable parameter: by-value/const scalar ordinal/enum/bool (a
      compile-time constant argument is always an ordconstn), never written }
    function para_specializable(pv : tparavarsym; code : tnode) : boolean;
      begin
        result:=false;
        if vo_is_hidden_para in pv.varoptions then
          exit;
        if not(pv.varspez in [vs_value,vs_const]) then
          exit;
        if not assigned(pv.vardef) then
          exit;
        if not(pv.vardef.typ in [orddef,enumdef]) then
          exit;
        if not param_readonly(pv,code) then
          exit;
        result:=true;
      end;

    { -------- heuristic gate ------------------------------------------------- }

    { only clone when specialization can plausibly pay off: the body must
      contain a conditional or a loop whose folding the constant could enable }
    function has_control_flow(var n : tnode; arg : pointer) : foreachnoderesult;
      begin
        result:=fen_true;
        case n.nodetype of
          ifn,casen,forn,whilerepeatn:
            begin
              pboolean(arg)^:=true;
              result:=fen_norecurse_true;
            end;
          else
            ;
        end;
      end;

    function body_has_control_flow(code : tnode) : boolean;
      begin
        result:=false;
        foreachnodestatic(pm_postprocess,code,@has_control_flow,@result);
      end;

    { -------- stash ---------------------------------------------------------- }

    procedure ipacp_stash_candidate(pd : tprocdef; code : tnode;
      piflags : tprocinfoflags; hasnested : boolean);
      var
        stash : tipacpstash;
        i,vis : longint;
        pv : tparavarsym;
        elig : array of longint;
        neligible : longint;
      begin
        if not assigned(pd) or not assigned(code) then
          exit;
        ipacp_module_check;
        if hasnested then
          exit;
        if (piflags*[pi_has_assembler_block,pi_is_assembler,pi_uses_exceptions,
             pi_has_label,pi_has_global_goto,pi_calls_c_varargs,
             pi_has_open_array_parameter,pi_uses_threadvar])<>[] then
          exit;
        if not proc_eligible(pd) then
          exit;
        if not localst_is_simple(pd) then
          exit;
        if not body_is_safe(code) then
          exit;
        if node_count(code,ipacp_body_budget)>=ipacp_body_budget then
          exit;
        if not body_has_control_flow(code) then
          exit;

        { collect the visible indices of specializable parameters }
        setlength(elig,pd.paras.count);
        neligible:=0;
        vis:=0;
        for i:=0 to pd.paras.count-1 do
          begin
            pv:=tparavarsym(pd.paras[i]);
            if vo_is_hidden_para in pv.varoptions then
              continue;
            if para_specializable(pv,code) then
              begin
                elig[neligible]:=vis;
                inc(neligible);
              end;
            inc(vis);
          end;
        if neligible=0 then
          exit;

        stash:=tipacpstash.create;
        stash.calleepd:=pd;
        stash.bodytemplate:=code.getcopy;
        setlength(stash.eligibleparas,neligible);
        for i:=0 to neligible-1 do
          stash.eligibleparas[i]:=elig[i];
        stashlist.add(stash);
      end;

    function find_stash(pd : tprocdef) : tipacpstash;
      var
        i : longint;
      begin
        result:=nil;
        if not assigned(stashlist) then
          exit;
        for i:=0 to stashlist.count-1 do
          if tipacpstash(stashlist[i]).calleepd=pd then
            exit(tipacpstash(stashlist[i]));
      end;

    function para_is_eligible(stash : tipacpstash; visidx : longint) : boolean;
      var
        i : longint;
      begin
        result:=false;
        for i:=0 to high(stash.eligibleparas) do
          if stash.eligibleparas[i]=visidx then
            exit(true);
      end;

    { -------- clone body construction --------------------------------------- }

    type
      premap = ^tremap;
      tremap = record
        oldpd,newpd   : tprocdef;
        oldfuncret,newfuncret : tsym;
        targetpara    : tsym;         { callee paravarsym being specialized }
        constdef      : tdef;         { its type }
        constval      : tconstexprint;
        oldlocals     : TFPList;      { parallel old/new local maps }
        newlocals     : TFPList;
      end;

    function remap_local(ctx : premap; sym : tsym) : tsym;
      var
        i : longint;
      begin
        result:=nil;
        for i:=0 to ctx^.oldlocals.count-1 do
          if tsym(ctx^.oldlocals[i])=sym then
            exit(tsym(ctx^.newlocals[i]));
      end;

    function remap_body(var n : tnode; arg : pointer) : foreachnoderesult;
      var
        ctx : premap;
        ld  : tloadnode;
        idx : longint;
        newpv,newloc : tsym;
      begin
        result:=fen_true;
        ctx:=premap(arg);
        if n.nodetype<>loadn then
          exit;
        ld:=tloadnode(n);
        { specialized parameter -> literal constant }
        if ld.symtableentry=ctx^.targetpara then
          begin
            n:=cordconstnode.create(ctx^.constval,ctx^.constdef,false);
            typecheckpass(n);
            ld.free;
            exit;
          end;
        { a visible parameter -> clone's parameter of the same index }
        idx:=visible_index_of(ctx^.oldpd,ld.symtableentry);
        if idx>=0 then
          begin
            newpv:=nth_visible_para(ctx^.newpd,idx);
            if assigned(newpv) then
              begin
                ld.symtableentry:=newpv;
                ld.symtable:=ctx^.newpd.parast;
                { keep the reference count in step: repointing a load without
                  bumping refs leaves e.g. the funcret at refs=0, which makes
                  gen_load_return_value emit an *uninitialized* result }
                newpv.IncRefCount;
              end;
            exit;
          end;
        { a plain local, or one of the funcret-role syms (the $result local and
          its function-name / RESULT aliases, all mapped onto the clone's
          $result by map_funcret) }
        newloc:=remap_local(ctx,ld.symtableentry);
        if assigned(newloc) then
          begin
            ld.symtableentry:=newloc;
            ld.symtable:=newloc.owner;
            newloc.IncRefCount;
            exit;
          end;
        { fallback: any stray funcret-flagged sym -> the clone's $result }
        if assigned(ctx^.newfuncret) and
           (ld.symtableentry is tabstractvarsym) and
           (vo_is_funcret in tabstractvarsym(ld.symtableentry).varoptions) then
          begin
            ld.symtableentry:=ctx^.newfuncret;
            ld.symtable:=ctx^.newfuncret.owner;
            exit;
          end;
        { anything else (unit-level var/const, another routine) stays as-is }
      end;

    { classify a funcret-role sym: 0 = the $result local, 1 = the function-name
      alias, 2 = the RESULT alias; -1 if not a funcret sym }
    function funcret_role(sym : tsym) : longint;
      begin
        result:=-1;
        if not(sym is tabstractvarsym) then
          exit;
        if not(vo_is_funcret in tabstractvarsym(sym).varoptions) then
          exit;
        if vo_is_result in tabstractvarsym(sym).varoptions then
          result:=2
        else if sym.typ=localvarsym then
          result:=0
        else
          result:=1;
      end;

    function find_funcret_role(pd : tprocdef; role : longint) : tsym;
      var
        i : longint;
      begin
        result:=nil;
        for i:=0 to pd.localst.symlist.count-1 do
          if funcret_role(tsym(pd.localst.symlist[i]))=role then
            exit(tsym(pd.localst.symlist[i]));
      end;

    { record old->new for each funcret role present in both procdefs, so loads
      of the callee's result local and its aliases retarget onto the clone's
      matching sym (built by insert_funcret_local) }
    procedure map_funcret(oldpd,newpd : tprocdef; ctx : premap);
      var
        i : longint;
        oldsym : tsym;
      begin
        { map the callee's $result local and every result alias (function-name
          and RESULT) DIRECTLY onto the clone's $result local, so the clone body
          reads/writes the funcret local straight (exactly as a `Result`-keyword
          function lowers) -- writing through a copied alias confuses the -O2
          register allocator into coalescing the result away from the return
          register.  Carry over the callee funcret's read/written varstate. }
        if not assigned(newpd.funcretsym) then
          exit;
        for i:=0 to oldpd.localst.symlist.count-1 do
          begin
            oldsym:=tsym(oldpd.localst.symlist[i]);
            if funcret_role(oldsym)<0 then
              continue;
            if oldsym is tabstractvarsym then
              tabstractvarsym(newpd.funcretsym).varstate:=tabstractvarsym(oldsym).varstate;
            ctx^.oldlocals.add(oldsym);
            ctx^.newlocals.add(newpd.funcretsym);
          end;
      end;

    { build the clone's localst as a copy of the callee's, recording old->new }
    procedure clone_locals(oldpd,newpd : tprocdef; ctx : premap);
      var
        i : longint;
        sym : tsym;
        old,nw : tlocalvarsym;
      begin
        for i:=0 to oldpd.localst.symlist.count-1 do
          begin
            sym:=tsym(oldpd.localst.symlist[i]);
            if sym.typ<>localvarsym then
              continue;
            { funcret local(s) are rebuilt by insert_funcret_local and remapped
              structurally -- do not copy them }
            if vo_is_funcret in tlocalvarsym(sym).varoptions then
              continue;
            old:=tlocalvarsym(sym);
            nw:=clocalvarsym.create(old.realname,old.varspez,old.vardef,old.varoptions);
            nw.register_sym;
            newpd.localst.insertsym(nw);
            nw.varstate:=old.varstate;
            ctx^.oldlocals.add(old);
            ctx^.newlocals.add(nw);
          end;
      end;

    function build_clone(stash : tipacpstash; visidx : longint;
      const val : tconstexprint; const clonerealname,clonemangled : string;
      out clonecode : tnode) : tprocdef;
      var
        clonepd : tprocdef;
        targetpv : tparavarsym;
        ctx : tremap;
      begin
        result:=nil;
        clonecode:=nil;
        targetpv:=nth_visible_para(stash.calleepd,visidx);
        if not assigned(targetpv) then
          exit;

        clonepd:=create_procdef_alias(stash.calleepd,clonerealname,clonemangled,
          stash.calleepd.owner,nil,tsk_none,nil);
        clonepd.forwarddef:=false;
        clonepd.interfacedef:=false;
        { never let the clone itself become an inline/clone target }
        include(clonepd.procoptions,po_noinline);
        if not is_void(clonepd.returndef) then
          insert_funcret_local(clonepd);

        clonecode:=stash.bodytemplate.getcopy;

        ctx.oldpd:=stash.calleepd;
        ctx.newpd:=clonepd;
        ctx.oldfuncret:=stash.calleepd.funcretsym;
        ctx.newfuncret:=clonepd.funcretsym;
        ctx.targetpara:=targetpv;
        ctx.constdef:=targetpv.vardef;
        ctx.constval:=val;
        ctx.oldlocals:=TFPList.create;
        ctx.newlocals:=TFPList.create;
        try
          clone_locals(stash.calleepd,clonepd,@ctx);
          map_funcret(stash.calleepd,clonepd,@ctx);
          foreachnodestatic(pm_postprocess,clonecode,@remap_body,@ctx);
        finally
          ctx.oldlocals.free;
          ctx.newlocals.free;
        end;
        result:=clonepd;
      end;

    { -------- call retargeting ---------------------------------------------- }

    function clone_key(pd : tprocdef; visidx : longint; const val : tconstexprint) : string;
      begin
        result:=hexstr(ptrint(pd),sizeof(ptrint)*2)+'_'+tostr(visidx)+'_'+tostr(val.svalue);
      end;

    function clones_of_routine(pd : tprocdef) : longint;
      var
        i : longint;
        prefix : string;
      begin
        result:=0;
        prefix:=hexstr(ptrint(pd),sizeof(ptrint)*2)+'_';
        for i:=0 to clonecache.count-1 do
          if copy(clonecache.NameOfIndex(i),1,length(prefix))=prefix then
            inc(result);
      end;

    { get-or-create the clone for (callee,visidx,val); returns its procsym or
      nil (budget/cap exceeded).  A newly-created clone is appended to PENDING. }
    function get_clone(stash : tipacpstash; visidx : longint;
      const val : tconstexprint; pending : TFPObjectList;
      const pos : tfileposinfo) : tprocsym;
      var
        key,rn,mn : string;
        clonepd : tprocdef;
        clonecode : tnode;
        vstr : string;
      begin
        result:=nil;
        key:=clone_key(stash.calleepd,visidx,val);
        clonepd:=tprocdef(clonecache.Find(key));
        if assigned(clonepd) then
          exit(tprocsym(clonepd.procsym));
        if module_clones>=ipacp_clones_per_module then
          begin
            OptRemark(pos,'ipacp','size budget exceeded: '+stash.calleepd.procsym.realname+
              ' (module clone cap)');
            exit;
          end;
        if clones_of_routine(stash.calleepd)>=ipacp_clones_per_routine then
          begin
            OptRemark(pos,'ipacp','size budget exceeded: '+stash.calleepd.procsym.realname+
              ' (per-routine clone cap)');
            exit;
          end;
        vstr:=tostr(val.svalue);
        if val.svalue<0 then
          vstr:='n'+tostr(-val.svalue);
        rn:='$ipacp$'+stash.calleepd.procsym.realname+'$p'+tostr(visidx)+'v'+vstr;
        mn:=stash.calleepd.mangledname+'$ipacp$p'+tostr(visidx)+'v'+vstr;
        clonepd:=build_clone(stash,visidx,val,rn,mn,clonecode);
        if not assigned(clonepd) then
          exit;
        clonecache.add(key,clonepd);
        inc(module_clones);
        pending.add(tipacpclone.create(clonepd,clonecode));
        result:=tprocsym(clonepd.procsym);
      end;

    { context threaded through the caller-body scan }
    type
      pscanctx = ^tscanctx;
      tscanctx = record
        callerpd : tprocdef;
        pending  : TFPObjectList;
      end;

    { find, in call node N, the first argument that is a constant for an
      eligible parameter of STASH; returns its visible index or -1 }
    function first_const_para(stash : tipacpstash; call : tcallnode;
      out val : tconstexprint) : longint;
      var
        pn : tcallparanode;
        visidx : longint;
      begin
        result:=-1;
        val:=0;
        pn:=tcallparanode(call.left);
        while assigned(pn) do
          begin
            if assigned(pn.left) and (pn.left.nodetype=ordconstn) and
               assigned(pn.parasym) then
              begin
                visidx:=visible_index_of(stash.calleepd,pn.parasym);
                if (visidx>=0) and para_is_eligible(stash,visidx) then
                  begin
                    val:=tordconstnode(pn.left).value;
                    exit(visidx);
                  end;
              end;
            pn:=tcallparanode(pn.right);
          end;
      end;

    { deep-copy a (possibly nil) callparanode chain }
    function getcopyparas(l : tnode) : tnode;
      begin
        if assigned(l) then
          result:=l.getcopy
        else
          result:=nil;
      end;

    function scan_calls(var n : tnode; arg : pointer) : foreachnoderesult;
      var
        ctx : pscanctx;
        call : tcallnode;
        stash : tipacpstash;
        calleepd : tprocdef;
        visidx : longint;
        val : tconstexprint;
        clonesym : tprocsym;
        newcall : tnode;
      begin
        result:=fen_true;
        if n.nodetype<>calln then
          exit;
        ctx:=pscanctx(arg);
        call:=tcallnode(n);
        { direct static calls only: no method pointer, real procdef bound }
        if assigned(call.methodpointer) then
          exit;
        if not assigned(call.procdefinition) or
           (call.procdefinition.typ<>procdef) then
          exit;
        calleepd:=tprocdef(call.procdefinition);
        { never specialize a call to the routine currently being compiled into
          itself here -- and cross-clone chaining is out of scope }
        stash:=find_stash(calleepd);
        if not assigned(stash) then
          exit;
        visidx:=first_const_para(stash,call,val);
        if visidx<0 then
          exit;
        clonesym:=get_clone(stash,visidx,val,ctx^.pending,call.fileinfo);
        if not assigned(clonesym) then
          exit;
        { retarget by rebuilding a fresh call to the clone's procsym with a
          copy of the (still un-lowered) argument list -- the re-typecheck
          rebinds every callparanode.parasym onto the clone's parast }
        newcall:=ccallnode.create(
          tcallparanode(getcopyparas(call.left)),
          clonesym,clonesym.owner,nil,[],nil);
        typecheckpass(newcall);
        OptRemark(call.fileinfo,'ipacp','call to '+calleepd.procsym.realname+
          ' specialized for '+nth_visible_para(calleepd,visidx).realname+'='+
          tostr(val.svalue));
        n.free;
        n:=newcall;
      end;

    procedure ipacp_process_calls(callerpd : tprocdef; var code : tnode;
      pending : TFPObjectList);
      var
        ctx : tscanctx;
      begin
        if not assigned(code) or not assigned(pending) then
          exit;
        ipacp_module_check;
        ctx.callerpd:=callerpd;
        ctx.pending:=pending;
        foreachnodestatic(pm_postprocess,code,@scan_calls,@ctx);
      end;

end.
