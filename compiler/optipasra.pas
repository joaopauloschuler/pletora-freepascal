{
    Interprocedural scalar replacement of aggregates via function cloning
    (-OoIPASRA) -- part (b) of the gcc -fipa-sra port (gcc/ipa-sra.cc).

    Part (a) (dead-parameter elimination, -OoDEADPARA, optdeadpara.pas) drops a
    never-read parameter with a caller-side, signature-preserving elision.  This
    pass performs the SIGNATURE-CHANGING half: it splits a `const` record
    parameter whose fields are only READ inside the callee into individual
    by-value scalar parameters, so the callee stops dereferencing through the
    aggregate reference and the fields land in registers.  Neural-api passes
    configuration records and TNNetVolume references down helper chains where a
    callee touches two or three fields -- after this transform the indirection
    disappears with no source change.

    FPC is single-pass with immediate code generation, so an already-compiled
    callee's signature cannot be rewritten in place (there is no phase where a
    whole unit's bodies coexist -- see optipacp.pas for the full argument).  The
    only forward-viable design is therefore the SAME call-site-driven CLONE that
    -OoIPACP (optipacp.pas) uses.  This module is its sibling: instead of
    specializing a scalar parameter on a compile-time constant, it rewrites the
    clone's SIGNATURE (const-record param -> N by-value scalar params, one per
    read field) and each redirected call site (pass `rec.f1, rec.f2` instead of
    `rec`):

      * When an eligible routine's body has just been parsed and type-checked --
        but BEFORE it is first-passed and code-generated -- a deep copy of that
        (type-checked, not-yet-lowered) body is stashed as a template together
        with the set of const-record parameters that may be split and, for each,
        the exact read fields (ipasra_stash_candidate).

      * A LATER caller that passes a SIDE-EFFECT-FREE record actual for every
        splittable parameter of a stashed routine gets a fresh out-of-line CLONE
        procdef synthesised (ipasra_process_calls):
          - the clone is a bare copy of the original whose visible signature has
            the record parameter(s) REPLACED by N by-value scalar parameters (one
            per read field, at the record parameter's ordinal slot);
          - the stashed template is copied and every field read of a split
            parameter (`subscriptn(loadn(rec),f)`) is rewritten to a load of the
            matching scalar parameter -- the memory indirection is gone from the
            clone body;
          - the caller's call node is rebuilt to the clone's procsym, the single
            record actual replaced by N field-read actuals `rec.f1 .. rec.fN`
            (the re-typecheck rebinds every callparanode onto the clone's parast).

    Unlike -OoIPACP a clone does NOT depend on the call-site values, so there is
    at most ONE clone per routine (the split is a fixed restructuring), shared by
    every call site whose actuals are all decomposable.  Growth is bounded by a
    node-count budget on the callee body and a per-module clone cap.

    Correctness notes:
      - the ORIGINAL routine is never modified, so any call site we do not touch
        (side-effecting record actual, budget exceeded, ineligible callee) keeps
        the general body; cloning is purely additive;
      - only a `const`/`constref` record parameter is split (guaranteed
        read-only by the language) and only when EVERY use of it in the body is a
        direct field read (no address-taken, no whole-aggregate copy or pass-on,
        no write) -- so the split scalars carry exactly the values the field
        reads would have produced;
      - the record actual at a redirected call must be side-effect-free (checked
        with might_have_sideeffects+mhs_exceptions), so re-reading its fields N
        times instead of passing it once is observationally identical and
        preserves evaluation order of the other arguments;
      - split fields are limited to a small number (<=4) of ordinal / enum /
        float / pointer-sized fields; managed fields and bitpacked records are
        refused (they would change lifetime bookkeeping or have bit offsets);
      - virtual/exported/external/address-taken/inline/nested callees are never
        cloned (proc_eligible), matching -OoIPACP's intra-unit reach.

    Same-unit only for this first landing (no PPU tag, no PPU-version bump); the
    cross-unit reach (streaming the body as inlininginfo like -OoIPACP does) and
    the WPO program-wide variant remain open.

    Opt-in via -OoIPASRA (NOT part of -O4 defaults).

    This module is free software; see the FPC copying conditions.
}
unit optipasra;

{$i fpcdefs.inc}

interface

    uses
      cclasses,
      globtype,node,symdef;

    { Reset the per-module stash and clone cache.  Cheap; only clears on change. }
    procedure ipasra_module_check;

    { If PD is an eligible clone target, stash a deep copy of its type-checked
      (not-yet-first-passed) body CODE as a template for later callers.  Must be
      called on the final node tree BEFORE generate_code_tree lowers/frees it. }
    procedure ipasra_stash_candidate(pd : tprocdef; code : tnode;
      piflags : tprocinfoflags; hasnested : boolean);

    { Scan CALLERPD's type-checked (not-yet-first-passed) body CODE for direct
      calls that pass a side-effect-free record actual to every splittable
      parameter of a stashed routine.  For each, get-or-create the routine's
      split clone and rebuild the call to it.  Newly-created clones are appended
      to PENDING (each a tipasraclone carrying the clone procdef and its still
      uncompiled body); the caller (psub) compiles them afterwards. }
    procedure ipasra_process_calls(callerpd : tprocdef; var code : tnode;
      pending : TFPObjectList);

    type
      { a clone whose body has been synthesised but not yet code-generated }
      tipasraclone = class
        clonepd   : tprocdef;
        clonecode : tnode;
        constructor create(apd : tprocdef; acode : tnode);
      end;

implementation

    uses
      globals,cutils,verbose,fmodule,
      symconst,symbase,symtype,symsym,symtable,
      defutil,paramgr,pparautl,pass_1,htypechk,symcreat,
      nbas,nld,nmem,ncal,ncon,nutils,
      optutils;

    const
      { do not clone a callee whose body exceeds this many nodes }
      ipasra_body_budget = 800;
      { at most this many clones per module (bounds total code growth) }
      ipasra_clones_per_module = 64;
      { at most this many scalar fields split out of one record parameter }
      ipasra_max_fields = 4;

    { ---- per-parameter split descriptor ------------------------------------ }

    type
      { one const-record parameter that will be split, plus its read fields }
      tsplitdesc = record
        recpv  : tparavarsym;              { the callee's record paravarsym }
        recdef : trecorddef;               { its type }
        visidx : longint;                  { its visible (non-hidden) index }
        fields : array of tfieldvarsym;    { the distinct read fields, in
                                             declaration order }
      end;
      tsplitdescs = array of tsplitdesc;

    { ---- per-module state --------------------------------------------------- }

    type
      tipasrastash = class
        calleepd     : tprocdef;
        bodytemplate : tnode;              { deep copy: typechecked, NOT firstpassed }
        splits       : tsplitdescs;        { the parameters to split }
        destructor destroy; override;
      end;

    var
      cur_module    : pointer = nil;       { tmodule the state belongs to }
      stashlist     : TFPObjectList = nil; { of tipasrastash, keyed linearly }
      clonecache    : TFPHashList = nil;   { calleepd-key -> clone tprocdef }
      module_clones : longint = 0;

    constructor tipasraclone.create(apd : tprocdef; acode : tnode);
      begin
        clonepd:=apd;
        clonecode:=acode;
      end;

    destructor tipasrastash.destroy;
      begin
        if assigned(bodytemplate) then
          bodytemplate.free;
        inherited destroy;
      end;

    procedure ipasra_clear;
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

    procedure ipasra_module_check;
      begin
        if cur_module<>pointer(current_module) then
          begin
            ipasra_clear;
            cur_module:=pointer(current_module);
            stashlist:=TFPObjectList.create(true);
            clonecache:=TFPHashList.create;
          end;
      end;

    { ---- eligibility -------------------------------------------------------- }

    { the whole body must be free of exception handling, inline assembler,
      labels and gotos (as in optipacp/optpartialinline) -- scan the tree since
      the procinfo flags are only set during firstpass, not yet run }
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
      variables (plus the funcret local) may appear (as in optipacp) }
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
            if (sym is tabstractvarsym) and
               (vo_is_funcret in tabstractvarsym(sym).varoptions) then
              continue;
            if sym.typ<>localvarsym then
              exit;
          end;
        result:=true;
      end;

    { same structural screen as optipacp.proc_eligible (intra-unit variant):
      unit-private ordinary routine, no hidden high/special-array params, a
      register-returned (or void) result, not a method/generic/inline/virtual/
      external routine, a single unambiguous procdef }
    function proc_eligible(pd : tprocdef) : boolean;
      var
        i : longint;
        pv : tparavarsym;
      begin
        result:=false;
        if not(pd.proctypeoption in [potype_procedure,potype_function]) then
          exit;
        for i:=0 to pd.paras.count-1 do
          begin
            pv:=tparavarsym(pd.paras[i]);
            if vo_is_high_para in pv.varoptions then
              exit;
            if assigned(pv.vardef) and is_special_array(pv.vardef) then
              exit;
          end;
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
        { po_noinline is deliberately NOT rejected: a noinline callee stays
          out-of-line, so splitting its record parameter is exactly where the
          ABI win is real, and cloning is not inlining (the clone is a separate
          out-of-line routine).  po_inline IS rejected -- its body has already
          been consumed for inlining locally. }
        if ([po_external,po_virtualmethod,po_abstractmethod,po_assembler,
             po_exports,po_interrupt,po_inline,
             po_classmethod,po_varargs]*pd.procoptions)<>[] then
          exit;
        if not assigned(pd.procsym) or (pd.procsym.typ<>procsym) then
          exit;
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

    { a field may be split into a by-value scalar parameter: an instance field
      of ordinal / enum / float / pointer-sized scalar type, not managed }
    function field_splittable(fsym : tfieldvarsym) : boolean;
      begin
        result:=false;
        if not assigned(fsym) or not assigned(fsym.vardef) then
          exit;
        if sp_static in fsym.symoptions then
          exit;
        if is_managed_type(fsym.vardef) then
          exit;
        if not((fsym.vardef.typ in [orddef,enumdef,pointerdef]) or
               is_single(fsym.vardef) or is_double(fsym.vardef)) then
          exit;
        result:=true;
      end;

    { -------- per-parameter field-read analysis ----------------------------- }

    type
      pfieldscan = ^tfieldscan;
      tfieldscan = record
        target   : tsym;                   { the record paravarsym under test }
        totalld  : longint;                { total loads of TARGET }
        consumed : longint;                { loads that are a field read's base }
        fields   : array of tfieldvarsym;  { distinct fields read (decl order) }
      end;

    procedure fieldscan_add(ctx : pfieldscan; fsym : tfieldvarsym);
      var
        i : longint;
      begin
        for i:=0 to high(ctx^.fields) do
          if ctx^.fields[i]=fsym then
            exit;
        setlength(ctx^.fields,length(ctx^.fields)+1);
        ctx^.fields[high(ctx^.fields)]:=fsym;
      end;

    function fieldscan_cb(var n : tnode; arg : pointer) : foreachnoderesult;
      var
        ctx : pfieldscan;
        sub : tsubscriptnode;
      begin
        result:=fen_true;
        ctx:=pfieldscan(arg);
        case n.nodetype of
          loadn:
            if tloadnode(n).symtableentry=ctx^.target then
              inc(ctx^.totalld);
          subscriptn:
            begin
              sub:=tsubscriptnode(n);
              if assigned(sub.left) and (sub.left.nodetype=loadn) and
                 (tloadnode(sub.left).symtableentry=ctx^.target) then
                begin
                  inc(ctx^.consumed);
                  fieldscan_add(ctx,sub.vs);
                end;
            end;
          else
            ;
        end;
      end;

    { determine whether const/constref record parameter PV of PD is splittable
      in body CODE: every use of it must be a direct field read of a splittable
      field, at most ipasra_max_fields distinct fields.  On success SD is filled
      (recpv, recdef, visidx, fields) and the function returns true. }
    function analyze_split_param(pd : tprocdef; pv : tparavarsym; code : tnode;
      out sd : tsplitdesc) : boolean;
      var
        ctx : tfieldscan;
        i : longint;
      begin
        result:=false;
        if vo_is_hidden_para in pv.varoptions then
          exit;
        { only genuinely read-only record references: const / constref }
        if not(pv.varspez in [vs_const,vs_constref]) then
          exit;
        if not assigned(pv.vardef) or (pv.vardef.typ<>recorddef) then
          exit;
        if is_packed_record_or_object(pv.vardef) then
          exit;
        if is_managed_type(pv.vardef) then
          exit;
        ctx.target:=pv;
        ctx.totalld:=0;
        ctx.consumed:=0;
        ctx.fields:=nil;
        foreachnodestatic(pm_postprocess,code,@fieldscan_cb,@ctx);
        { must have at least one use and every use a field read }
        if (ctx.totalld=0) or (ctx.consumed<>ctx.totalld) then
          exit;
        if (length(ctx.fields)=0) or (length(ctx.fields)>ipasra_max_fields) then
          exit;
        for i:=0 to high(ctx.fields) do
          if not field_splittable(ctx.fields[i]) then
            exit;
        sd.recpv:=pv;
        sd.recdef:=trecorddef(pv.vardef);
        sd.visidx:=visible_index_of(pd,pv);
        if sd.visidx<0 then
          exit;
        sd.fields:=ctx.fields;
        result:=true;
      end;

    { collect every splittable const-record parameter of PD in body CODE }
    function screen_body(pd : tprocdef; code : tnode; out splits : tsplitdescs) : boolean;
      var
        i : longint;
        pv : tparavarsym;
        sd : tsplitdesc;
      begin
        result:=false;
        splits:=nil;
        if not assigned(pd) or not assigned(code) then
          exit;
        if not proc_eligible(pd) then
          exit;
        if not localst_is_simple(pd) then
          exit;
        if not body_is_safe(code) then
          exit;
        if node_count(code,ipasra_body_budget)>=ipasra_body_budget then
          exit;
        for i:=0 to pd.paras.count-1 do
          begin
            pv:=tparavarsym(pd.paras[i]);
            if analyze_split_param(pd,pv,code,sd) then
              begin
                setlength(splits,length(splits)+1);
                splits[high(splits)]:=sd;
              end;
          end;
        result:=length(splits)>0;
      end;

    procedure ipasra_stash_candidate(pd : tprocdef; code : tnode;
      piflags : tprocinfoflags; hasnested : boolean);
      var
        stash : tipasrastash;
        splits : tsplitdescs;
      begin
        if not assigned(pd) or not assigned(code) then
          exit;
        ipasra_module_check;
        if hasnested then
          exit;
        if (piflags*[pi_has_assembler_block,pi_is_assembler,pi_uses_exceptions,
             pi_has_label,pi_has_global_goto,pi_calls_c_varargs,
             pi_has_open_array_parameter,pi_uses_threadvar])<>[] then
          exit;
        if not screen_body(pd,code,splits) then
          exit;
        stash:=tipasrastash.create;
        stash.calleepd:=pd;
        stash.bodytemplate:=code.getcopy;
        stash.splits:=splits;
        stashlist.add(stash);
      end;

    function find_stash(pd : tprocdef) : tipasrastash;
      var
        i : longint;
      begin
        result:=nil;
        if not assigned(stashlist) then
          exit;
        for i:=0 to stashlist.count-1 do
          if tipasrastash(stashlist[i]).calleepd=pd then
            exit(tipasrastash(stashlist[i]));
      end;

    function split_of_param(stash : tipasrastash; pv : tsym) : longint;
      var
        i : longint;
      begin
        result:=-1;
        for i:=0 to high(stash.splits) do
          if tsym(stash.splits[i].recpv)=pv then
            exit(i);
      end;

    { -------- clone body construction --------------------------------------- }

    type
      { the scalar parameter a given (record-param, field) field read maps to }
      tfieldmap = record
        recpv : tsym;
        fsym  : tfieldvarsym;
        newpv : tparavarsym;
      end;

      premap = ^tremap;
      tremap = record
        oldpd,newpd   : tprocdef;
        newfuncret    : tsym;
        oldparams     : TFPList;        { non-split visible params: old->new }
        newparams     : TFPList;
        fieldmaps     : array of tfieldmap;
        oldlocals     : TFPList;        { locals: old->new }
        newlocals     : TFPList;
      end;

    function map_param(ctx : premap; sym : tsym) : tsym;
      var
        i : longint;
      begin
        result:=nil;
        for i:=0 to ctx^.oldparams.count-1 do
          if tsym(ctx^.oldparams[i])=sym then
            exit(tsym(ctx^.newparams[i]));
      end;

    function map_field(ctx : premap; recpv : tsym; fsym : tfieldvarsym) : tparavarsym;
      var
        i : longint;
      begin
        result:=nil;
        for i:=0 to high(ctx^.fieldmaps) do
          if (ctx^.fieldmaps[i].recpv=recpv) and (ctx^.fieldmaps[i].fsym=fsym) then
            exit(ctx^.fieldmaps[i].newpv);
      end;

    function map_local(ctx : premap; sym : tsym) : tsym;
      var
        i : longint;
      begin
        result:=nil;
        for i:=0 to ctx^.oldlocals.count-1 do
          if tsym(ctx^.oldlocals[i])=sym then
            exit(tsym(ctx^.newlocals[i]));
      end;

    function is_split_recpv(ctx : premap; sym : tsym) : boolean;
      var
        i : longint;
      begin
        result:=false;
        for i:=0 to high(ctx^.fieldmaps) do
          if ctx^.fieldmaps[i].recpv=sym then
            exit(true);
      end;

    function remap_body(var n : tnode; arg : pointer) : foreachnoderesult;
      var
        ctx : premap;
        ld  : tloadnode;
        sub : tsubscriptnode;
        newpv,newloc : tsym;
        repl : tnode;
      begin
        result:=fen_true;
        ctx:=premap(arg);
        { a field read of a split record parameter -> load of its scalar param }
        if n.nodetype=subscriptn then
          begin
            sub:=tsubscriptnode(n);
            if assigned(sub.left) and (sub.left.nodetype=loadn) then
              begin
                newpv:=map_field(ctx,tloadnode(sub.left).symtableentry,sub.vs);
                if assigned(newpv) then
                  begin
                    repl:=cloadnode.create(newpv,ctx^.newpd.parast);
                    tparavarsym(newpv).IncRefCount;
                    n.free;
                    n:=repl;
                  end;
              end;
            exit;
          end;
        if n.nodetype<>loadn then
          exit;
        ld:=tloadnode(n);
        { a bare load of a split record parameter is consumed by its enclosing
          subscriptn (handled above); leave it untouched here }
        if is_split_recpv(ctx,ld.symtableentry) then
          exit;
        { a surviving (non-split) visible parameter -> the clone's copy }
        newpv:=map_param(ctx,ld.symtableentry);
        if assigned(newpv) then
          begin
            ld.symtableentry:=newpv;
            ld.symtable:=ctx^.newpd.parast;
            tabstractvarsym(newpv).IncRefCount;
            exit;
          end;
        { a plain local, or a funcret-role sym mapped onto the clone's $result }
        newloc:=map_local(ctx,ld.symtableentry);
        if assigned(newloc) then
          begin
            ld.symtableentry:=newloc;
            ld.symtable:=newloc.owner;
            tabstractvarsym(newloc).IncRefCount;
            exit;
          end;
        { fallback: any stray funcret-flagged sym -> the clone's $result }
        if assigned(ctx^.newfuncret) and
           (ld.symtableentry is tabstractvarsym) and
           (vo_is_funcret in tabstractvarsym(ld.symtableentry).varoptions) then
          begin
            ld.symtableentry:=ctx^.newfuncret;
            ld.symtable:=ctx^.newfuncret.owner;
          end;
      end;

    { re-establish the "address taken" property on the clone's own symbols (see
      optipacp.mark_addrtaken_cb for the full rationale) }
    function mark_addrtaken_cb(var n : tnode; arg : pointer) : foreachnoderesult;
      var
        inner : tnode;
      begin
        result:=fen_true;
        if n.nodetype<>addrn then
          exit;
        inner:=taddrnode(n).left;
        if assigned(inner) and (inner.nodetype=loadn) and
           (tloadnode(inner).symtableentry is tabstractvarsym) and
           (tloadnode(inner).symtableentry.typ in [localvarsym,paravarsym]) then
          make_not_regable(inner,[ra_addr_regable,ra_addr_taken]);
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

    procedure map_funcret(oldpd,newpd : tprocdef; ctx : premap);
      var
        i : longint;
        oldsym : tsym;
      begin
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

    { collect the ordered non-hidden paravarsyms of PD }
    procedure collect_visible(pd : tprocdef; list : TFPList);
      var
        i : longint;
        pv : tparavarsym;
      begin
        for i:=0 to pd.paras.count-1 do
          begin
            pv:=tparavarsym(pd.paras[i]);
            if vo_is_hidden_para in pv.varoptions then
              continue;
            list.add(pv);
          end;
      end;

    { collect the (visible) paravarsyms currently in PARAST symlist, in order }
    procedure collect_parast_paras(pd : tprocdef; list : TFPList);
      var
        i : longint;
      begin
        for i:=0 to pd.parast.symlist.count-1 do
          if tsym(pd.parast.symlist[i]).typ=paravarsym then
            list.add(pd.parast.symlist[i]);
      end;

    { build the split clone of STASH.calleepd; CLONECODE receives the synthesised
      (uncompiled) body. }
    function build_clone(stash : tipasrastash;
      const clonerealname,clonemangled : string;
      out clonecode : tnode) : tprocdef;
      var
        clonepd : tprocdef;
        ctx : tremap;
        oldvis,newvis : TFPList;
        i,f,si : longint;
        recpv : tparavarsym;
        base : word;
        scalarpv : tparavarsym;
        sd : tsplitdesc;
      begin
        result:=nil;
        clonecode:=nil;

        clonepd:=tprocdef(stash.calleepd.getcopyas(procdef,pc_bareproc,'__FPCW_',true));
        clonepd.setmangledname(clonemangled);

        { pair the callee's visible params with the bare copy's (same order),
          then splice each record param out and its scalar fields in }
        oldvis:=TFPList.create;
        newvis:=TFPList.create;
        ctx.oldparams:=TFPList.create;
        ctx.newparams:=TFPList.create;
        ctx.fieldmaps:=nil;
        try
          collect_visible(stash.calleepd,oldvis);
          collect_parast_paras(clonepd,newvis);
          if oldvis.count<>newvis.count then
            begin
              clonepd:=nil;
              exit;
            end;
          for i:=0 to newvis.count-1 do
            begin
              si:=split_of_param(stash,tsym(oldvis[i]));
              if si<0 then
                begin
                  ctx.oldparams.add(oldvis[i]);
                  ctx.newparams.add(newvis[i]);
                  continue;
                end;
              { split parameter: replace the copy's record paravarsym with one
                by-value scalar per read field, at the record param's slot }
              sd:=stash.splits[si];
              recpv:=tparavarsym(newvis[i]);
              base:=recpv.paranr;
              for f:=0 to high(sd.fields) do
                begin
                  scalarpv:=cparavarsym.create(
                    '$sra$'+recpv.realname+'$'+sd.fields[f].realname,
                    base+f,vs_value,sd.fields[f].vardef,[]);
                  clonepd.parast.insertsym(scalarpv);
                  setlength(ctx.fieldmaps,length(ctx.fieldmaps)+1);
                  ctx.fieldmaps[high(ctx.fieldmaps)].recpv:=tsym(oldvis[i]);
                  ctx.fieldmaps[high(ctx.fieldmaps)].fsym:=sd.fields[f];
                  ctx.fieldmaps[high(ctx.fieldmaps)].newpv:=scalarpv;
                end;
              clonepd.parast.deletesym(recpv);
            end;
        finally
          oldvis.free;
          newvis.free;
        end;

        { finish the clone exactly as create_procdef_alias would, but over the
          now-rewritten visible parameter list }
        finish_copied_procdef(clonepd,clonerealname,stash.calleepd.owner,nil);
        clonepd.parast.SymList.ForEachCall(@insert_hidden_para,clonepd);
        insert_self_and_vmt_para(clonepd);
        insert_funcret_para(clonepd);
        clonepd.calcparas;
        clonepd.forwarddef:=false;
        clonepd.interfacedef:=false;
        include(clonepd.procoptions,po_noinline);
        if not is_void(clonepd.returndef) then
          insert_funcret_local(clonepd);

        { synthesise the body: copy the template and remap it onto the clone }
        clonecode:=stash.bodytemplate.getcopy;
        ctx.oldpd:=stash.calleepd;
        ctx.newpd:=clonepd;
        ctx.newfuncret:=clonepd.funcretsym;
        ctx.oldlocals:=TFPList.create;
        ctx.newlocals:=TFPList.create;
        try
          clone_locals(stash.calleepd,clonepd,@ctx);
          map_funcret(stash.calleepd,clonepd,@ctx);
          foreachnodestatic(pm_postprocess,clonecode,@remap_body,@ctx);
          foreachnodestatic(pm_postprocess,clonecode,@mark_addrtaken_cb,nil);
        finally
          ctx.oldlocals.free;
          ctx.newlocals.free;
        end;
        ctx.oldparams.free;
        ctx.newparams.free;
        result:=clonepd;
      end;

    { -------- call retargeting ---------------------------------------------- }

    function clone_key(pd : tprocdef) : string;
      begin
        result:=hexstr(ptrint(pd),sizeof(ptrint)*2);
      end;

    { get-or-create the one split clone of STASH.calleepd; nil if the module
      clone cap is exceeded }
    function get_clone(stash : tipasrastash; pending : TFPObjectList;
      const pos : tfileposinfo) : tprocsym;
      var
        key,rn,mn : string;
        clonepd : tprocdef;
        clonecode : tnode;
      begin
        result:=nil;
        key:=clone_key(stash.calleepd);
        clonepd:=tprocdef(clonecache.Find(key));
        if assigned(clonepd) then
          exit(tprocsym(clonepd.procsym));
        if module_clones>=ipasra_clones_per_module then
          begin
            OptRemark(pos,'ipasra','size budget exceeded: '+
              stash.calleepd.procsym.realname+' (module clone cap)');
            exit;
          end;
        rn:='$ipasra$'+stash.calleepd.procsym.realname;
        mn:=stash.calleepd.mangledname+'$ipasra';
        clonepd:=build_clone(stash,rn,mn,clonecode);
        if not assigned(clonepd) then
          exit;
        clonecache.add(key,clonepd);
        inc(module_clones);
        pending.add(tipasraclone.create(clonepd,clonecode));
        result:=tprocsym(clonepd.procsym);
      end;

    { context threaded through the caller-body scan }
    type
      pscanctx = ^tscanctx;
      tscanctx = record
        callerpd : tprocdef;
        pending  : TFPObjectList;
      end;

    { the callparanode of CALL whose parasym is PV, or nil }
    function paranode_of(call : tcallnode; pv : tsym) : tcallparanode;
      var
        pn : tcallparanode;
      begin
        result:=nil;
        pn:=tcallparanode(call.left);
        while assigned(pn) do
          begin
            if tsym(pn.parasym)=pv then
              exit(pn);
            pn:=tcallparanode(pn.right);
          end;
      end;

    { every splittable parameter of STASH must receive a side-effect-free actual
      of exactly the record type at this call, otherwise the site cannot be
      decomposed }
    function site_decomposable(stash : tipasrastash; call : tcallnode) : boolean;
      var
        i : longint;
        pn : tcallparanode;
      begin
        result:=false;
        for i:=0 to high(stash.splits) do
          begin
            pn:=paranode_of(call,tsym(stash.splits[i].recpv));
            if not assigned(pn) or not assigned(pn.left) then
              exit;
            if pn.left.resultdef<>stash.splits[i].recdef then
              exit;
            if might_have_sideeffects(pn.left,[mhs_exceptions]) then
              exit;
          end;
        result:=true;
      end;

    { rebuild CALL's argument chain against the split clone: every argument is
      copied except a split record actual, which becomes N field-read actuals in
      declaration order at its slot }
    function build_split_paras(stash : tipasrastash; call : tcallnode) : tcallparanode;
      var
        origlist : TFPList;
        exprs : TFPList;
        pn : tcallparanode;
        si,i,f : longint;
        chain : tcallparanode;
        sd : tsplitdesc;
      begin
        result:=nil;
        origlist:=TFPList.create;
        exprs:=TFPList.create;
        try
          pn:=tcallparanode(call.left);
          while assigned(pn) do
            begin
              origlist.add(pn);
              pn:=tcallparanode(pn.right);
            end;
          for i:=0 to origlist.count-1 do
            begin
              pn:=tcallparanode(origlist[i]);
              si:=split_of_param(stash,tsym(pn.parasym));
              if si<0 then
                exprs.add(pn.left.getcopy)
              else
                begin
                  { the argument chain is in REVERSE parameter order (call.left
                    is the last argument), while the clone's scalar params were
                    inserted in ascending field order; emit the field reads in
                    reverse so they line up with the clone's parameter slots }
                  sd:=stash.splits[si];
                  for f:=high(sd.fields) downto 0 do
                    exprs.add(csubscriptnode.create(sd.fields[f],pn.left.getcopy));
                end;
            end;
          { link preserving the collected order (exprs[0] becomes call.left) }
          chain:=nil;
          for i:=exprs.count-1 downto 0 do
            chain:=ccallparanode.create(tnode(exprs[i]),chain);
          result:=chain;
        finally
          origlist.free;
          exprs.free;
        end;
      end;

    function scan_calls(var n : tnode; arg : pointer) : foreachnoderesult;
      var
        ctx : pscanctx;
        call : tcallnode;
        stash : tipasrastash;
        calleepd : tprocdef;
        clonesym : tprocsym;
        newcall : tnode;
      begin
        result:=fen_true;
        if n.nodetype<>calln then
          exit;
        ctx:=pscanctx(arg);
        call:=tcallnode(n);
        if assigned(call.methodpointer) then
          exit;
        if not assigned(call.procdefinition) or
           (call.procdefinition.typ<>procdef) then
          exit;
        calleepd:=tprocdef(call.procdefinition);
        stash:=find_stash(calleepd);
        if not assigned(stash) then
          exit;
        if not site_decomposable(stash,call) then
          exit;
        clonesym:=get_clone(stash,ctx^.pending,call.fileinfo);
        if not assigned(clonesym) then
          exit;
        newcall:=ccallnode.create(build_split_paras(stash,call),
          clonesym,clonesym.owner,nil,[],nil);
        typecheckpass(newcall);
        OptRemark(call.fileinfo,'ipasra','call to '+calleepd.procsym.realname+
          ' rewritten to split-parameter clone');
        n.free;
        n:=newcall;
      end;

    procedure ipasra_process_calls(callerpd : tprocdef; var code : tnode;
      pending : TFPObjectList);
      var
        ctx : tscanctx;
      begin
        if not assigned(code) or not assigned(pending) then
          exit;
        ipasra_module_check;
        ctx.callerpd:=callerpd;
        ctx.pending:=pending;
        foreachnodestatic(pm_postprocess,code,@scan_calls,@ctx);
      end;

end.
