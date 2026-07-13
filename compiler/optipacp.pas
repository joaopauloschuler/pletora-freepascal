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

    Opt-in via -OoIPACP (NOT part of -O4 defaults).

    CROSS-UNIT cloning (no new PPU tags, no PPU-version bump): an eligible
    routine that is reachable from another unit (an interface routine, or one
    already inline) has its pre-firstpass body tree RETAINED as inlininginfo --
    the very vehicle cross-unit inlining already streams into the PPU -- via the
    same DEVIRT-style retention (WITHOUT po_inline, so ordinary call/inlining
    behaviour is unchanged; the producer gate is ipacp_crossunit_retain_candidate,
    invoked from psub.generate_code).  A caller in a USED unit recovers that
    streamed body (make_crossunit_stash), INDEPENDENTLY re-runs the full
    eligibility screen on the loaded copy -- so no eligibility verdict has to be
    serialized and the caller vouches for soundness itself -- and clones it just
    like an intra-unit template.  A cross-unit clone is instantiated in the
    CALLER's module (like a generic specialization): its code is emitted into
    the caller's object, the per-module caps count per instantiating module, and
    its mangled name carries the caller module's name (and it is a hidden/local
    symbol) so two units that specialize the same used-unit routine on the same
    constant never collide at link time.  The referenced unit-private symbols of
    the callee body are made linkable by the same export_local_ref machinery
    cross-unit inlining relies on (run by CreateInlineInfo at retention).

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

    { True when PD (a routine in the unit currently being compiled) should have
      its body tree retained as inlininginfo so it is streamed into the PPU as a
      cross-unit IPACP clone template.  Cross-unit producer-side gate; see the
      body for the eligibility screen.  Retention itself (CreateInlineInfo) is
      done by the caller in psub so this unit needs no psub dependency. }
    function ipacp_crossunit_retain_candidate(pd : tprocdef; code : tnode;
      piflags : tprocinfoflags; hasnested : boolean) : boolean;

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
      defutil,paramgr,pparautl,pass_1,htypechk,
      nbas,nld,nmem,ncal,ncon,nflw,nutils,
      optutils,
      symcreat;

    const
      { do not clone a callee whose body exceeds this many nodes }
      ipacp_body_budget = 400;
      { at most this many distinct clones per original routine }
      ipacp_clones_per_routine = 4;
      { at most this many clones per module (bounds total code growth) }
      ipacp_clones_per_module = 64;

    { ---- constant descriptors ---------------------------------------------- }

    type
      { one compile-time constant actual bound for a specializable parameter }
      tipacpconst = record
        def    : tdef;             { the parameter's declared type }
        isreal : boolean;          { true => realval (single/double), else ordval }
        ordval : tconstexprint;
        realval : bestreal;
      end;

      { one (visible-parameter, constant) specialization pair }
      tipacpspec = record
        visidx : longint;
        c      : tipacpconst;
      end;
      tipacpspecs = array of tipacpspec;

    { build the literal node for a constant descriptor (typechecked) }
    function make_const_node(const c : tipacpconst) : tnode;
      begin
        if c.isreal then
          result:=crealconstnode.create(c.realval,c.def)
        else
          result:=cordconstnode.create(c.ordval,c.def,false);
        typecheckpass(result);
      end;

    { a name/key token identifying one spec; only [A-Za-z0-9] characters so it
      is a valid mangled-name fragment.  Floats key on their BIT PATTERN (NOT
      the textual value): two literals that print alike but differ in bits must
      get distinct clones, and vice-versa.  Only single/double actuals are
      eligible, so the value is narrowed to a 64-bit double first: this both
      keeps the key stable (bestreal is `extended`, whose sizeof carries
      nondeterministic padding bytes that would defeat identical-value sharing)
      and makes bit-identical values map to one clone. }
    function real_bits_hex(v : bestreal) : string;
      var
        d : double;
        q : qword;
      begin
        d:=double(v);
        q:=pqword(@d)^;
        result:=hexstr(q,16);
      end;

    function spec_token(const s : tipacpspec) : string;
      begin
        result:='p'+tostr(s.visidx);
        if s.c.isreal then
          result:=result+'f'+real_bits_hex(s.c.realval)
        else if s.c.ordval.svalue<0 then
          result:=result+'vn'+tostr(-s.c.ordval.svalue)
        else
          result:=result+'v'+tostr(s.c.ordval.svalue);
      end;

    { human-readable value for -OoREPORT remarks }
    function spec_valstr(const c : tipacpconst) : string;
      begin
        if c.isreal then
          begin
            str(c.realval,result);
            { str() left-pads a non-negative real with a blank; drop it so the
              remark reads `k=2.0...` not `k= 2.0...` }
            if (length(result)>0) and (result[1]=' ') then
              delete(result,1,1);
          end
        else
          result:=tostr(c.ordval.svalue);
      end;

    { ---- per-module state --------------------------------------------------- }

    type
      tipacpstash = class
        calleepd     : tprocdef;
        bodytemplate : tnode;        { deep copy: typechecked, NOT firstpassed }
        eligibleparas : array of longint;  { visible indices of substitutable params }
        crossunit    : boolean;      { template came from a used unit's PPU }
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
          { addrn (taking the address of a frame variable) used to be rejected
            here: the clone rebuilds its localst/parast fresh and re-uses an
            already-typecheck-marked body copy, so the "@var forces the var into
            memory" property (addr_taken on the SYMBOL) was not re-derived on the
            clone's new symbol, and the code generator internalerrored (2006111510)
            taking the address of a register-resident var.  That is now fixed
            structurally in build_clone (mark_addrtaken_cb re-sets addr_taken on
            the clone's own symbols after the remap), so address-of-frame-variable
            routines are eligible again. }
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

    { ALLOWGLOBAL relaxes the owner-symtable check so a routine exported from a
      unit's INTERFACE (globalsymtable) is eligible as a cross-unit clone target
      -- such a routine is exactly the one a caller in another unit can reach.
      When false (the intra-unit path) only unit-private (staticsymtable)
      routines qualify, as before. }
    function proc_eligible(pd : tprocdef; allowglobal : boolean) : boolean;
      var
        i : longint;
        pv : tparavarsym;
      begin
        result:=false;
        if not(pd.proctypeoption in [potype_procedure,potype_function]) then
          exit;
        { reject routines whose signature carries a hidden high-length parameter
          (open array / array of const): the clone is a same-signature alias, but
          rebuilding a call to it copies only the visible argument nodes, so the
          hidden high para is left unbound and the re-typecheck reports a
          parameter-count mismatch.  This is the reliable structural equivalent
          of the pi_has_open_array_parameter procinfo flag, which is set during
          firstpass and is therefore NOT yet available at pre-firstpass stash
          time (a routine whose only callers are in the main program body would
          otherwise slip past that flag and be cloned incorrectly). }
        for i:=0 to pd.paras.count-1 do
          begin
            pv:=tparavarsym(pd.paras[i]);
            if vo_is_high_para in pv.varoptions then
              exit;
            if assigned(pv.vardef) and is_special_array(pv.vardef) then
              exit;
          end;
        { only a register-returned (or void) result: a result returned via a
          hidden pointer parameter (managed/large types) needs funcret handling
          we do not replicate -- skip it }
        if not is_void(pd.returndef) and
           paramanager.ret_in_param(pd.returndef,pd) then
          exit;
        if assigned(pd.struct) then
          exit;
        if allowglobal then
          begin
            if not(pd.owner.symtabletype in [staticsymtable,globalsymtable]) then
              exit;
          end
        else if pd.owner.symtabletype<>staticsymtable then
          exit;
        if pd.parast.symtablelevel>normal_function_level then
          exit;
        if [df_generic,df_specialization]*pd.defoptions<>[] then
          exit;
        { po_inline is NOT rejected on the cross-unit path: an inline routine
          already carries a PPU-streamed body tree, which is exactly the clone
          template we want to reuse.  On the intra-unit path it stays rejected
          (its body has already been consumed for inlining locally). }
        if ([po_external,po_virtualmethod,po_abstractmethod,po_assembler,
             po_exports,po_interrupt,po_noinline,
             po_classmethod,po_varargs]*pd.procoptions)<>[] then
          exit;
        if (not allowglobal) and (po_inline in pd.procoptions) then
          exit;
        if not assigned(pd.procsym) or (pd.procsym.typ<>procsym) then
          exit;
        { an overloaded name has several procdefs; we clone one specific procdef,
          so require a single, unambiguous definition either way }
        if tprocsym(pd.procsym).ProcdefList.Count<>1 then
          exit;
        { a separate forward/interface declaration means earlier-parsed call
          sites bind this name on the intra-unit path; a cross-unit callee is
          reached precisely THROUGH its interface declaration, so allow it }
        if (not allowglobal) and pd.interfacedef then
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

    { STRUCTURAL_ONLY suppresses the pv.varstate early-out: varstate is a
      reliable read-only witness only for a routine whose paravarsyms have not
      yet been through their own codegen.  On the cross-unit path the callee's
      ORIGINAL live paravarsyms may already have been code-generated in the same
      compilation (e.g. -B builds the used unit in-memory first), which flips a
      never-written value param's varstate to vs_written even though the body
      never assigns it.  The exhaustive scan_param_write walk (assignment /
      address-of / var/out/constref passing) is the authoritative test and is
      always run; only the varstate shortcut is skipped cross-unit. }
    function param_readonly(pv : tparavarsym; code : tnode;
      structural_only : boolean) : boolean;
      var
        ctx : twritescan;
      begin
        result:=false;
        { const parameters are guaranteed read-only by the language;
          value parameters must not have been written }
        if pv.varspez=vs_value then
          begin
            if (not structural_only) and (pv.varstate in [vs_written,vs_readwritten]) then
              exit;
          end
        else if pv.varspez<>vs_const then
          exit;
        ctx.target:=pv;
        ctx.safe:=true;
        foreachnodestatic(pm_postprocess,code,@scan_param_write,@ctx);
        result:=ctx.safe;
      end;

    { a specializable parameter: a by-value/const, never-written parameter whose
      compile-time constant argument the clone can drop into the body as a
      literal.  Eligible types:
        - scalar ordinal/enum/bool  (constant argument is an ordconstn), and
        - single/double float       (constant argument is a realconstn).
      Managed types (ansistring/widestring/interfaces/variants/dynarrays) and
      shortstrings are deliberately NOT eligible: their constant argument is not
      a plain literal node the remap could substitute, substituting them would
      change lifetime/refcount bookkeeping, and the clone's parast/localst copy
      would need init/final adjustments we do not replicate.  Currency is a
      floatdef but is fixed-point (value_currency, not value_real) so it is
      excluded here as well. }
    function para_specializable(pv : tparavarsym; code : tnode;
      structural_only : boolean) : boolean;
      begin
        result:=false;
        if vo_is_hidden_para in pv.varoptions then
          exit;
        if not(pv.varspez in [vs_value,vs_const]) then
          exit;
        if not assigned(pv.vardef) then
          exit;
        if not((pv.vardef.typ in [orddef,enumdef]) or
               (is_single(pv.vardef) or is_double(pv.vardef))) then
          exit;
        if not param_readonly(pv,code,structural_only) then
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

    { The structural screens shared by the intra-unit stash, the cross-unit
      producer-side retention gate and the cross-unit consumer-side on-demand
      stash.  Returns the visible indices of specializable parameters in ELIG
      (function result = their count); 0 means "not a clone candidate".
      ALLOWGLOBAL is threaded into proc_eligible so a unit's exported (interface)
      routine qualifies on the cross-unit paths but not the intra-unit one. }
    function screen_body(pd : tprocdef; code : tnode; allowglobal : boolean;
      out elig : array of longint) : longint;
      var
        i,vis : longint;
        pv : tparavarsym;
      begin
        result:=0;
        if not assigned(pd) or not assigned(code) then
          exit;
        if not proc_eligible(pd,allowglobal) then
          exit;
        if not localst_is_simple(pd) then
          exit;
        if not body_is_safe(code) then
          exit;
        if node_count(code,ipacp_body_budget)>=ipacp_body_budget then
          exit;
        if not body_has_control_flow(code) then
          exit;
        vis:=0;
        for i:=0 to pd.paras.count-1 do
          begin
            pv:=tparavarsym(pd.paras[i]);
            if vo_is_hidden_para in pv.varoptions then
              continue;
            if para_specializable(pv,code,allowglobal) then
              begin
                elig[result]:=vis;
                inc(result);
              end;
            inc(vis);
          end;
      end;

    procedure ipacp_stash_candidate(pd : tprocdef; code : tnode;
      piflags : tprocinfoflags; hasnested : boolean);
      var
        stash : tipacpstash;
        i,neligible : longint;
        elig : array of longint;
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
        setlength(elig,pd.paras.count);
        neligible:=screen_body(pd,code,false,elig);
        if neligible=0 then
          exit;

        stash:=tipacpstash.create;
        stash.calleepd:=pd;
        stash.crossunit:=false;
        stash.bodytemplate:=code.getcopy;
        setlength(stash.eligibleparas,neligible);
        for i:=0 to neligible-1 do
          stash.eligibleparas[i]:=elig[i];
        stashlist.add(stash);
      end;

    { Cross-unit PRODUCER gate (called at codegen of a routine in the defining
      unit, BEFORE do_firstpass, exactly like the intra-unit stash): true when
      this routine should have its body tree retained as inlininginfo so it is
      streamed into the unit's PPU and can serve as a clone template for callers
      in OTHER units.  Same screens as the stash but with ALLOWGLOBAL=true so an
      exported (interface) routine qualifies; PIFLAGS filters the assembler /
      exception / open-array / threadvar cases the tree scan cannot see.  Kept
      cheap and side-effect-free: it only decides retention. }
    function ipacp_crossunit_retain_candidate(pd : tprocdef; code : tnode;
      piflags : tprocinfoflags; hasnested : boolean) : boolean;
      var
        elig : array of longint;
      begin
        result:=false;
        if not assigned(pd) or not assigned(code) then
          exit;
        if hasnested then
          exit;
        if (piflags*[pi_has_assembler_block,pi_is_assembler,pi_uses_exceptions,
             pi_has_label,pi_has_global_goto,pi_calls_c_varargs,
             pi_has_open_array_parameter,pi_uses_threadvar])<>[] then
          exit;
        { only routines reachable from another unit are worth streaming for
          cross-unit cloning: an interface (globalsymtable) routine, or a
          unit-private one that is already inline (its tree is streamed anyway) }
        if not((pd.owner.symtabletype=globalsymtable) or
               (po_inline in pd.procoptions)) then
          exit;
        setlength(elig,pd.paras.count);
        result:=screen_body(pd,code,true,elig)>0;
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

    { Consumer-side cross-unit stash: PD is a routine defined in a USED unit
      whose body tree we recovered from its PPU-streamed inlininginfo (the same
      vehicle cross-unit inlining rides).  Independently re-run the eligibility
      screens on that loaded tree -- so the caller unit VERIFIES soundness for
      itself and no eligibility verdict has to be serialized -- and, if it
      passes, build a stash from a COPY of the inline body (the original belongs
      to PD and must not be freed by the stash).  The resulting clones are
      instantiated in the CALLER's module.  Cached in stashlist so repeated call
      sites in this unit share one screen. }
    function make_crossunit_stash(pd : tprocdef) : tipacpstash;
      var
        stash : tipacpstash;
        i,neligible : longint;
        elig : array of longint;
        body : tnode;
      begin
        result:=nil;
        if pd.owner.iscurrentunit then
          exit;
        if not pd.has_inlininginfo then
          exit;
        if not assigned(pd.inlininginfo) or not assigned(pd.inlininginfo^.code) then
          exit;
        body:=pd.inlininginfo^.code;
        setlength(elig,pd.paras.count);
        neligible:=screen_body(pd,body,true,elig);
        if neligible=0 then
          exit;
        stash:=tipacpstash.create;
        stash.calleepd:=pd;
        stash.crossunit:=true;
        stash.bodytemplate:=body.getcopy;
        setlength(stash.eligibleparas,neligible);
        for i:=0 to neligible-1 do
          stash.eligibleparas[i]:=elig[i];
        stashlist.add(stash);
        result:=stash;
      end;

    { the stash for PD, whether it was stashed locally (intra-unit) or must be
      recovered from a used unit's PPU inline body (cross-unit) }
    function find_or_make_stash(pd : tprocdef) : tipacpstash;
      begin
        result:=find_stash(pd);
        if not assigned(result) then
          result:=make_crossunit_stash(pd);
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
      { one resolved substitution: the callee paravarsym and the literal value }
      tremaptarget = record
        para : tsym;
        c    : tipacpconst;
      end;

      premap = ^tremap;
      tremap = record
        oldpd,newpd   : tprocdef;
        oldfuncret,newfuncret : tsym;
        targets       : array of tremaptarget;   { params being specialized }
        oldlocals     : TFPList;      { parallel old/new local maps }
        newlocals     : TFPList;
      end;

    function remap_target_index(ctx : premap; sym : tsym) : longint;
      var
        i : longint;
      begin
        result:=-1;
        for i:=0 to high(ctx^.targets) do
          if ctx^.targets[i].para=sym then
            exit(i);
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
        idx:=remap_target_index(ctx,ld.symtableentry);
        if idx>=0 then
          begin
            n:=make_const_node(ctx^.targets[idx].c);
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

    { Re-establish the "address taken" property on the clone's own symbols.
      Taking @var forces that variable into memory; the frontend records this by
      setting addr_taken on the var's SYMBOL during typecheck of the addrn.  The
      clone body is a copy of an already-typecheck-marked template whose loads we
      just repointed onto the clone's freshly-built local/param symbols -- symbols
      on which typecheck never ran, so their addr_taken bit is clear even though
      the body still takes their address.  The register allocator would then keep
      such a var in a register and the code generator would internalerror
      (2006111510) taking its address.  Walk the remapped body and set addr_taken
      on every local/param whose address it takes, exactly as typecheck would. }
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
          { same call taddrnode.pass_typecheck makes: mark the symbol
            address-taken AND force it out of a register (varregable:=vr_none),
            so the code generator gives it a memory location }
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

    function build_clone(stash : tipacpstash; const specs : tipacpspecs;
      const clonerealname,clonemangled : string;
      out clonecode : tnode) : tprocdef;
      var
        clonepd : tprocdef;
        targetpv : tparavarsym;
        ctx : tremap;
        i : longint;
        ownerst : tsymtable;
      begin
        result:=nil;
        clonecode:=nil;
        if length(specs)=0 then
          exit;

        { intra-unit clones live beside the original in the defining unit; a
          cross-unit clone is instantiated in the CALLER's module (like a
          generic specialization) so its code is emitted into THIS unit's object
          and the per-module caps count per instantiating module.  Placing it in
          the caller's staticsymtable also makes it a unit-local symbol, so two
          units that instantiate the same specialization never collide at link
          time (their mangled names additionally carry the module name). }
        if stash.crossunit then
          ownerst:=current_module.localsymtable
        else
          ownerst:=stash.calleepd.owner;

        clonepd:=create_procdef_alias(stash.calleepd,clonerealname,clonemangled,
          ownerst,nil,tsk_none,nil);
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
        setlength(ctx.targets,length(specs));
        for i:=0 to high(specs) do
          begin
            targetpv:=nth_visible_para(stash.calleepd,specs[i].visidx);
            if not assigned(targetpv) then
              begin
                clonecode.free;
                clonecode:=nil;
                exit;
              end;
            ctx.targets[i].para:=targetpv;
            ctx.targets[i].c:=specs[i].c;
            { the literal takes the parameter's declared type }
            ctx.targets[i].c.def:=targetpv.vardef;
          end;
        ctx.oldlocals:=TFPList.create;
        ctx.newlocals:=TFPList.create;
        try
          clone_locals(stash.calleepd,clonepd,@ctx);
          map_funcret(stash.calleepd,clonepd,@ctx);
          foreachnodestatic(pm_postprocess,clonecode,@remap_body,@ctx);
          { after the loads point at the clone's own symbols, re-derive the
            address-taken property those symbols must carry (see above) }
          foreachnodestatic(pm_postprocess,clonecode,@mark_addrtaken_cb,nil);
        finally
          ctx.oldlocals.free;
          ctx.newlocals.free;
        end;
        result:=clonepd;
      end;

    { -------- call retargeting ---------------------------------------------- }

    { the mangled/name/cache-key suffix for a whole (possibly multi-param) tuple:
      the concatenation of the per-spec tokens in visible-index order }
    function specs_suffix(const specs : tipacpspecs) : string;
      var
        i : longint;
      begin
        result:='';
        for i:=0 to high(specs) do
          result:=result+spec_token(specs[i]);
      end;

    function clone_key(pd : tprocdef; const specs : tipacpspecs) : string;
      begin
        result:=hexstr(ptrint(pd),sizeof(ptrint)*2)+'_'+specs_suffix(specs);
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

    { get-or-create the clone specialized on the whole SPECS tuple; returns its
      procsym or nil (budget/cap exceeded).  A newly-created clone is appended to
      PENDING and counts as ONE clone against both caps. }
    function get_clone(stash : tipacpstash; const specs : tipacpspecs;
      pending : TFPObjectList; const pos : tfileposinfo) : tprocsym;
      var
        key,rn,mn : string;
        clonepd : tprocdef;
        clonecode : tnode;
      begin
        result:=nil;
        if length(specs)=0 then
          exit;
        key:=clone_key(stash.calleepd,specs);
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
        rn:='$ipacp$'+stash.calleepd.procsym.realname+'$'+specs_suffix(specs);
        { the cross-unit mangled name carries the INSTANTIATING module's name so
          two units that specialize the same used-unit routine on the same
          constant emit distinct (unit-local) symbols and never collide at link
          time; the intra-unit name is unchanged so existing behaviour/tests are
          byte-stable }
        if stash.crossunit then
          mn:=stash.calleepd.mangledname+'$ipacp$'+current_module.modulename^+'$'+
              specs_suffix(specs)
        else
          mn:=stash.calleepd.mangledname+'$ipacp$'+specs_suffix(specs);
        clonepd:=build_clone(stash,specs,rn,mn,clonecode);
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

    { insert SPEC into SPECS keeping the array sorted by ascending visidx (so a
      given constant tuple always produces the same key/name regardless of the
      textual argument order) }
    procedure insert_spec_sorted(var specs : tipacpspecs; const spec : tipacpspec);
      var
        i,j : longint;
      begin
        i:=length(specs);
        setlength(specs,i+1);
        j:=i;
        while (j>0) and (specs[j-1].visidx>spec.visidx) do
          begin
            specs[j]:=specs[j-1];
            dec(j);
          end;
        specs[j]:=spec;
      end;

    { collect EVERY argument of call node CALL that is a compile-time constant
      (ordinal or single/double float) bound to an eligible parameter of STASH.
      A call site that passes constants for several eligible params yields a
      multi-element tuple here, so it is specialized by ONE tuple clone rather
      than several single-param clones. }
    function collect_const_paras(stash : tipacpstash; call : tcallnode) : tipacpspecs;
      var
        pn : tcallparanode;
        visidx : longint;
        spec : tipacpspec;
      begin
        result:=nil;
        pn:=tcallparanode(call.left);
        while assigned(pn) do
          begin
            if assigned(pn.left) and assigned(pn.parasym) and
               (pn.left.nodetype in [ordconstn,realconstn]) then
              begin
                visidx:=visible_index_of(stash.calleepd,pn.parasym);
                if (visidx>=0) and para_is_eligible(stash,visidx) then
                  begin
                    spec.visidx:=visidx;
                    spec.c.def:=tparavarsym(pn.parasym).vardef;
                    if pn.left.nodetype=ordconstn then
                      begin
                        spec.c.isreal:=false;
                        spec.c.ordval:=tordconstnode(pn.left).value;
                        spec.c.realval:=0;
                      end
                    else
                      begin
                        spec.c.isreal:=true;
                        spec.c.ordval:=0;
                        spec.c.realval:=trealconstnode(pn.left).value_real;
                      end;
                    insert_spec_sorted(result,spec);
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

    { build the '<p1>=<v1>, <p2>=<v2>' fragment for the -OoREPORT remark }
    function specs_remark(calleepd : tprocdef; const specs : tipacpspecs) : string;
      var
        i : longint;
      begin
        result:='';
        for i:=0 to high(specs) do
          begin
            if i>0 then
              result:=result+', ';
            result:=result+nth_visible_para(calleepd,specs[i].visidx).realname+
              '='+spec_valstr(specs[i].c);
          end;
      end;

    function scan_calls(var n : tnode; arg : pointer) : foreachnoderesult;
      var
        ctx : pscanctx;
        call : tcallnode;
        stash : tipacpstash;
        calleepd : tprocdef;
        specs : tipacpspecs;
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
        { look for a clone template: either stashed locally (intra-unit) or
          recovered on demand from a used unit's PPU inline body (cross-unit) }
        stash:=find_or_make_stash(calleepd);
        if not assigned(stash) then
          exit;
        specs:=collect_const_paras(stash,call);
        if length(specs)=0 then
          exit;
        clonesym:=get_clone(stash,specs,ctx^.pending,call.fileinfo);
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
          ' specialized for '+specs_remark(calleepd,specs));
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
