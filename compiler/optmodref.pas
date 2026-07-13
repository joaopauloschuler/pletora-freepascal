{
    Interprocedural mod/ref memory-access summaries (-OoMODREF)

    A port of gcc's ipa-modref (gcc/ipa-modref.cc, default-on there at -O2 as
    -fipa-modref) that REFINES the binary pure/const verdict of -OoPURE
    (optpure.pas).  Where -OoPURE only answers "pure / const / impure", this pass
    records, per ordinary routine compiled in the current unit, a conservative
    MEMORY-ACCESS SUMMARY: what it READS and what it WRITES, each classified as

      mr_none    -- nothing externally observable (only its own non-escaping
                    locals / by-value parameters, which no caller can name),
      mr_byref   -- only memory reachable through its own by-reference
                    (var/out/const/constref) parameters,
      mr_unknown -- may touch arbitrary global / static / heap memory,

    plus a can_trap bit (the body may raise or trap).  A store or load in a
    caller that a call provably neither reads nor writes is no longer a barrier
    even though the callee is impure -- the motivating shape being a helper that
    writes only its own `out` parameter (bound to a caller local), which today
    kills every pending global store and blocks promoting a global across a loop
    in its caller.

    Because FPC is single-pass (each routine is code-generated immediately and
    its tree freed), the summary is computed bottom-up ON DEMAND at each
    routine's codegen, exactly like -OoPURE / -OoIPARA: callees compile before
    callers, so at a call site the callee's summary is already recorded (in this
    unit) or loaded from its ppu (cross-unit, the optsum_modref tag).  A callee's
    effect is mapped through the ACTUAL arguments at the call site into the
    caller's own frame.  Unlike -OoPURE there is NO query-time fixpoint: the
    stored fields ARE the final derived summary, so a forward / recursive callee
    whose summary is not yet available -- and any indirect / procvar / virtual /
    external / assembler callee, or a write through a dereferenced pointer --
    degrade conservatively to mr_unknown.

    Everything that cannot be proven is over-approximated to mr_unknown /
    can_trap, so refusing to refine is always sound: at worst a consumer keeps a
    barrier it could have dropped.

    This module is free software; see the FPC copying conditions.
}
unit optmodref;

{$i fpcdefs.inc}

interface

    uses
      node,ncal,symtype,symdef;

    const
      { the three-level read/write access lattice (stored in a byte so it
        serializes trivially; the join is numeric max) }
      mr_none    = 0;
      mr_byref   = 1;
      mr_unknown = 2;

    { analyse the (final) node tree CODE of routine PD and fill in its mod/ref
      summary (pd.modref_reads / modref_writes / modref_can_trap /
      modref_analyzed). }
    procedure AnalyzeProcModref(pd : tprocdef; code : tnode);

    { true if a usable mod/ref summary exists for PD (computed in this unit or
      loaded from its ppu). }
    function modref_summary_available(pd : tprocdef) : boolean;

    { PD's routine may raise or trap (unknown/unanalysed => assume yes). }
    function modref_pd_can_trap(pd : tprocdef) : boolean;

    { For a RESOLVED DIRECT call node CN, decide whether the call may READ or
      WRITE any globally-reachable memory (a static/global/heap location, or
      memory the current routine reaches through one of its own by-reference
      parameters), given each argument's actual.  A caller-local / by-value
      actual is invisible to the callee and contributes nothing.

      Consults -OoPURE's const/pure verdict first (const => neither, pure =>
      reads only) and otherwise the -OoMODREF summary.  Returns TRUE if any of
      those was usable (so reads_global/writes_global are meaningful); FALSE
      means no information -- the caller must treat the call as a full barrier. }
    function modref_call_effect(cn : tcallnode; out reads_global, writes_global : boolean) : boolean;

    { For a RESOLVED DIRECT call node CN, decide whether the call may READ (when
      FORWRITE is false) or WRITE (when FORWRITE is true) the SPECIFIC static /
      global variable S at this call site.  Returns TRUE unless the -OoMODREF
      summary proves S is excluded from that direction's footprint -- the
      per-location refinement of modref_call_effect's coarse reads_global /
      writes_global booleans (which cannot express "writes only static A").

      S is compared against the callee's serialized static set by MANGLED NAME
      (globally-unique, linker-stable), so a same-source-named static in another
      unit -- a distinct location with a distinct mangled name -- is correctly
      not matched.  When S is not a tstaticvarsym, or the summary is not exact,
      or the target is opaque, the result is the conservative TRUE. }
    function modref_call_may_access_static(cn : tcallnode; s : tsym; forwrite : boolean) : boolean;

implementation

    uses
      cutils,
      globtype,globals,
      symconst,symsym,
      defutil,
      nutils,nbas,nld,nmem,ncnv,ninl,
      optpure,optutils,
      compinnr;

    { ---- the read/write access lattice ------------------------------------- }

    function classify_sym(sym : tsym) : byte;
      begin
        if sym is tstaticvarsym then
          result:=mr_unknown
        else if sym is tparavarsym then
          begin
            { self is a reference to externally-observable object state }
            if vo_is_self in tparavarsym(sym).varoptions then
              result:=mr_unknown
            else if (tparavarsym(sym).varspez in [vs_var,vs_out,vs_const,vs_constref]) and
                    not(vo_is_funcret in tparavarsym(sym).varoptions) then
              { by-reference parameter: aliases caller storage }
              result:=mr_byref
            else
              { by-value / const-by-value / funcret: the routine's own copy }
              result:=mr_none;
          end
        else if sym is tlocalvarsym then
          result:=mr_none
        else
          { with-field, absolute var, unknown kind: be safe }
          result:=mr_unknown;
      end;


    { the static/global variable SYM denotes, or nil when SYM is not a nameable
      static. A tstaticvarsym is identified cross-unit by its (globally-unique,
      linker-stable) mangled name, so attributing a global access to it is sound;
      anything else (self/with-field/absolute/local/param) is NOT a nameable
      static and yields nil, which forces the caller to fall back to the coarse
      "any global" meaning. }
    function static_of_sym(sym : tsym) : tstaticvarsym;
      begin
        if sym is tstaticvarsym then
          result:=tstaticvarsym(sym)
        else
          result:=nil;
      end;

    { classify the ultimate base of an l-value / addressable expression: what
      memory, in the CURRENT routine's frame, does it denote? (mr_none for a
      non-escaping local / by-value parameter, mr_byref for something reached
      through a by-reference parameter, mr_unknown for a static/global, a pointer
      dereference or anything not recognised).  BASESYM is the by-reference
      parameter symbol the result mr_byref was reached through (nil otherwise),
      so a caller can attribute the access to a specific formal-parameter index.
      STATICSYM is the tstaticvarsym the result mr_unknown was reached through
      when the base is exactly a nameable static (nil otherwise -- e.g. a deref /
      heap / self / with-field access, which is unattributable), so a caller can
      attribute the access to a specific global. }
    function classify_lvalue_base_ex(t : tnode; out basesym : tsym; out staticsym : tstaticvarsym) : byte;
      begin
        basesym:=nil;
        staticsym:=nil;
        result:=mr_unknown;
        while assigned(t) do
          case t.nodetype of
            typeconvn:
              t:=ttypeconvnode(t).left;
            subscriptn:
              begin
                { a field of a class/interface/object INSTANCE is reached through
                  an implicit pointer -> heap; a record/object-value field lives
                  in the base's own storage, so descend to the base }
                if assigned(tsubscriptnode(t).left.resultdef) and
                   is_implicit_pointer_object_type(tsubscriptnode(t).left.resultdef) then
                  exit(mr_unknown);
                t:=tsubscriptnode(t).left;
              end;
            vecn:
              begin
                { a static-array element lives in the base variable's storage
                  (descend); a dynamic / open array / string element is heap or
                  aliased memory reached through a pointer }
                if not assigned(tvecnode(t).left.resultdef) or
                   not is_normal_array(tvecnode(t).left.resultdef) then
                  exit(mr_unknown);
                t:=tvecnode(t).left;
              end;
            derefn:
              exit(mr_unknown);
            loadn:
              begin
                result:=classify_sym(tloadnode(t).symtableentry);
                if result=mr_byref then
                  basesym:=tloadnode(t).symtableentry
                else if result=mr_unknown then
                  staticsym:=static_of_sym(tloadnode(t).symtableentry);
                exit;
              end;
            else
              exit(mr_unknown);
          end;
      end;

    function classify_lvalue_base(t : tnode) : byte;
      var
        dummy : tsym;
        dummys : tstaticvarsym;
      begin
        result:=classify_lvalue_base_ex(t,dummy,dummys);
      end;

    { index of a by-reference formal parameter SYM in its owning routine's
      ordered parameter list (paras), or -1 when SYM is not a parameter of PD or
      the index does not fit the 32-bit per-formal mask. Both the summary
      producer and every consumer derive the index the same deterministic way
      (paras is reconstructed identically from a ppu), so a mask bit means the
      same formal cross-unit without serialising any symbol identity. }
    function pd_para_index(pd : tprocdef; sym : tsym) : longint;
      begin
        result:=-1;
        if assigned(pd) and assigned(pd.paras) and (sym is tparavarsym) then
          begin
            result:=pd.paras.indexof(sym);
            if result>31 then
              result:=-1;
          end;
      end;


    { inline intrinsics that are genuinely side-effect-free, non-trapping value
      computations (same conservative whitelist as optpure.pure_inline). }
    function pure_inline(nr : tinlinenumber) : boolean;
      begin
        case nr of
          in_lo_word,in_hi_word,in_lo_long,in_hi_long,in_lo_qword,in_hi_qword,
          in_ord_x,in_chr_byte,
          in_abs_long,in_abs_real,in_sqr_real,in_sqrt_real,in_pi_real:
            result:=true;
          else
            result:=false;
        end;
      end;


    { ---- summary computation ---------------------------------------------- }

    const
      { how many distinct static/global variables one direction's set may hold
        before it overflows to the coarse "any global" meaning (smask_exact
        clears). Small and bounded: the serialized ppu image stays tiny and a
        consumer's membership test is a short linear scan. }
      MODREF_MAXSTATICS = 8;

    type
      pmodrefscan = ^tmodrefscan;
      tmodrefscan = record
        pd : tprocdef;      { the routine being analysed (for formal indexing) }
        reads : byte;
        writes : byte;
        reads_pmask : dword;
        writes_pmask : dword;
        pmask_exact : boolean;
        { per-static read/write sets (mangled names) and their exactness bit.
          When smask_exact holds, every unknown-global access was attributable to
          a nameable static that fit the set, so the mr_unknown footprint is
          EXACTLY these statics (plus any by-ref pmask actuals). Once an
          unattributable global/heap access is seen (or a set overflows),
          smask_exact clears and mr_unknown reverts to the coarse "any global". }
        reads_statics : array of ansistring;
        writes_statics : array of ansistring;
        smask_exact : boolean;
        can_trap : boolean;
      end;

    { add a static's mangled name to one direction's set, deduplicating; overflow
      past MODREF_MAXSTATICS clears smask_exact (the set becomes the coarse "any
      global"). Once inexact, nothing more need be recorded. }
    procedure add_static_name(ctx : pmodrefscan; iswrite : boolean; const name : ansistring);
      var
        i : longint;
      begin
        if not ctx^.smask_exact then
          exit;
        if iswrite then
          begin
            for i:=0 to high(ctx^.writes_statics) do
              if ctx^.writes_statics[i]=name then
                exit;
            if length(ctx^.writes_statics)>=MODREF_MAXSTATICS then
              begin
                ctx^.smask_exact:=false;
                exit;
              end;
            setlength(ctx^.writes_statics,length(ctx^.writes_statics)+1);
            ctx^.writes_statics[high(ctx^.writes_statics)]:=name;
          end
        else
          begin
            for i:=0 to high(ctx^.reads_statics) do
              if ctx^.reads_statics[i]=name then
                exit;
            if length(ctx^.reads_statics)>=MODREF_MAXSTATICS then
              begin
                ctx^.smask_exact:=false;
                exit;
              end;
            setlength(ctx^.reads_statics,length(ctx^.reads_statics)+1);
            ctx^.reads_statics[high(ctx^.reads_statics)]:=name;
          end;
      end;

    { record a nameable-static leaf access (STATICSYM<>nil) into the set, or, when
      the global access is UNATTRIBUTABLE (STATICSYM=nil: deref / heap / self /
      with-field / absolute), drop to the coarse "any global" meaning. }
    procedure record_static(ctx : pmodrefscan; staticsym : tstaticvarsym; iswrite : boolean);
      begin
        if assigned(staticsym) then
          add_static_name(ctx,iswrite,staticsym.mangledname)
        else
          ctx^.smask_exact:=false;
      end;

    { true if NAME is a member of the direction's serialized static set. }
    function static_name_in_set(const name : ansistring; const setarr : array of ansistring) : boolean;
      var
        i : longint;
      begin
        result:=true;
        for i:=0 to high(setarr) do
          if setarr[i]=name then
            exit;
        result:=false;
      end;

    { fold a callee's summary, mapped through the call's actual arguments, into
      the caller's accumulating summary. Coarse map: the max base classification
      over EVERY by-reference actual (the fallback used when a callee's per-formal
      mask is not exact). }
    function map_byref_actuals(cn : tcallnode; forwrite : boolean) : byte;
      var
        para : tcallparanode;
        c : byte;
        relevant : boolean;
      begin
        result:=mr_none;
        para:=tcallparanode(cn.left);
        while assigned(para) do
          begin
            if assigned(para.parasym) then
              begin
                if forwrite then
                  { only var/out actuals can be written by the callee }
                  relevant:=para.parasym.varspez in [vs_var,vs_out]
                else
                  relevant:=para.parasym.varspez in [vs_var,vs_out,vs_const,vs_constref];
                if relevant and assigned(para.paravalue) then
                  begin
                    c:=classify_lvalue_base(para.paravalue);
                    if c>result then
                      result:=c;
                  end;
              end;
            para:=tcallparanode(para.nextpara);
          end;
      end;


    { precise map: the max base classification over ONLY the by-reference actuals
      whose callee formal index is flagged in MASK (used when the callee's
      per-formal mask is exact). CALLEEPD is the resolved target. When a flagged
      actual is itself reached through one of the CALLER's own by-reference
      formals, that formal's index is OR-ed into CARRY (so the caller's summary
      can record which of ITS parameters the effect propagates through); if any
      such actual cannot be indexed within the mask, CARRYEXACT is cleared. }
    function map_byref_actuals_masked(cn : tcallnode; calleepd : tprocdef;
        mask : dword; callerpd : tprocdef; var carry : dword; var carryexact : boolean) : byte;
      var
        para : tcallparanode;
        c : byte;
        basesym : tsym;
        staticsym : tstaticvarsym;
        fidx,cidx : longint;
      begin
        result:=mr_none;
        para:=tcallparanode(cn.left);
        while assigned(para) do
          begin
            if assigned(para.parasym) and assigned(para.paravalue) then
              begin
                fidx:=pd_para_index(calleepd,para.parasym);
                if (fidx>=0) and ((mask and (dword(1) shl fidx))<>0) then
                  begin
                    c:=classify_lvalue_base_ex(para.paravalue,basesym,staticsym);
                    if c>result then
                      result:=c;
                    if c=mr_byref then
                      begin
                        cidx:=pd_para_index(callerpd,basesym);
                        if cidx>=0 then
                          carry:=carry or (dword(1) shl cidx)
                        else
                          carryexact:=false;
                      end;
                  end;
              end;
            para:=tcallparanode(para.nextpara);
          end;
      end;


    { a call target that must be treated as an opaque unknown (indirect /
      procvar / virtual / external / assembler / nested / aggregate-return) }
    function call_target_opaque(cn : tcallnode) : boolean;
      var
        pd : tprocdef;
      begin
        result:=true;
        if not assigned(cn.procdefinition) or not(cn.procdefinition is tprocdef) then
          exit;
        pd:=tprocdef(cn.procdefinition);
        if assigned(cn.methodpointer) and
           ((po_virtualmethod in pd.procoptions) or
            (po_abstractmethod in pd.procoptions)) then
          exit;
        if assigned(cn.funcretnode) or assigned(cn.callinitblock) or
           assigned(cn.callcleanupblock) then
          exit;
        if (po_external in pd.procoptions) or
           (po_assembler in pd.procoptions) or
           (pd.owner.symtabletype=localsymtable) then
          exit;
        result:=false;
      end;


    { record a direct by-reference access through parameter SYM into CTX's
      per-formal mask; a parameter that does not fit the mask drops CTX to
      inexact (the coarse mr_byref meaning) so precision never turns unsound. }
    procedure record_byref(ctx : pmodrefscan; sym : tsym; iswrite : boolean);
      var
        idx : longint;
      begin
        idx:=pd_para_index(ctx^.pd,sym);
        if idx<0 then
          ctx^.pmask_exact:=false
        else if iswrite then
          ctx^.writes_pmask:=ctx^.writes_pmask or (dword(1) shl idx)
        else
          ctx^.reads_pmask:=ctx^.reads_pmask or (dword(1) shl idx);
      end;


    { fold one direction of a resolved callee's by-ref summary into CTX, mapping
      its per-formal mask (or, when inexact, every by-ref actual) through the
      call. }
    procedure fold_byref_dir(ctx : pmodrefscan; cn : tcallnode; calleepd : tprocdef;
        calleemask : dword; calleeexact : boolean; forwrite : boolean);
      var
        c : byte;
      begin
        if calleeexact then
          begin
            if forwrite then
              c:=map_byref_actuals_masked(cn,calleepd,calleemask,ctx^.pd,ctx^.writes_pmask,ctx^.pmask_exact)
            else
              c:=map_byref_actuals_masked(cn,calleepd,calleemask,ctx^.pd,ctx^.reads_pmask,ctx^.pmask_exact);
          end
        else
          begin
            { the callee did not attribute its by-ref accesses to specific
              formals: fall back to every by-ref actual and, if that reaches
              caller storage through a by-ref parameter, drop to inexact (we
              cannot say WHICH caller formal) }
            c:=map_byref_actuals(cn,forwrite);
            if c=mr_byref then
              ctx^.pmask_exact:=false;
          end;
        if forwrite then
          begin
            if c>ctx^.writes then ctx^.writes:=c;
          end
        else if c>ctx^.reads then
          ctx^.reads:=c;
      end;


    { fold a resolved callee's mr_unknown direction: its global footprint is the
      union of its per-static set (when the callee is smask-exact) and its by-ref
      pmask actuals; an inexact callee contributes the coarse "any global" and
      clears our own smask_exact. }
    procedure fold_unknown_dir(ctx : pmodrefscan; cn : tcallnode; calleepd : tprocdef; forwrite : boolean);
      var
        i : longint;
      begin
        if forwrite then
          ctx^.writes:=mr_unknown
        else
          ctx^.reads:=mr_unknown;
        if calleepd.modref_smask_exact then
          begin
            if forwrite then
              for i:=0 to high(calleepd.modref_writes_statics) do
                add_static_name(ctx,true,calleepd.modref_writes_statics[i])
            else
              for i:=0 to high(calleepd.modref_reads_statics) do
                add_static_name(ctx,false,calleepd.modref_reads_statics[i]);
            { fold the by-ref part of the footprint too (kept in the pmask even for
              an mr_unknown direction when the callee is smask-exact) }
            if forwrite then
              fold_byref_dir(ctx,cn,calleepd,calleepd.modref_writes_pmask,calleepd.modref_pmask_exact,true)
            else
              fold_byref_dir(ctx,cn,calleepd,calleepd.modref_reads_pmask,calleepd.modref_pmask_exact,false);
          end
        else
          { the callee's global footprint is not enumerable: coarse "any global" }
          ctx^.smask_exact:=false;
      end;


    procedure fold_call(ctx : pmodrefscan; cn : tcallnode);
      var
        pd : tprocdef;
      begin
        if call_target_opaque(cn) then
          begin
            ctx^.reads:=mr_unknown;
            ctx^.writes:=mr_unknown;
            ctx^.can_trap:=true;
            ctx^.smask_exact:=false;
            exit;
          end;
        pd:=tprocdef(cn.procdefinition);
        { -OoPURE's stronger verdict stays authoritative where it holds }
        if proc_is_const(pd) then
          { reads nothing, writes nothing, cannot trap: contributes nothing }
          exit;
        if proc_is_pure(pd) then
          begin
            { may read arbitrary (unenumerable) global memory, writes nothing,
              non-trapping: coarse read footprint }
            if mr_unknown>ctx^.reads then
              ctx^.reads:=mr_unknown;
            ctx^.smask_exact:=false;
            exit;
          end;
        if modref_summary_available(pd) then
          begin
            case pd.modref_writes of
              mr_none: ;
              mr_byref:
                fold_byref_dir(ctx,cn,pd,pd.modref_writes_pmask,pd.modref_pmask_exact,true);
              else
                fold_unknown_dir(ctx,cn,pd,true);
            end;
            case pd.modref_reads of
              mr_none: ;
              mr_byref:
                fold_byref_dir(ctx,cn,pd,pd.modref_reads_pmask,pd.modref_pmask_exact,false);
              else
                fold_unknown_dir(ctx,cn,pd,false);
            end;
            if pd.modref_can_trap then
              ctx^.can_trap:=true;
            exit;
          end;
        { a resolved routine with no summary (e.g. forward / not yet analysed /
          in the same unresolved recursive SCC): fully conservative }
        ctx^.reads:=mr_unknown;
        ctx^.writes:=mr_unknown;
        ctx^.can_trap:=true;
        ctx^.smask_exact:=false;
      end;


    function modrefscan_node(var n : tnode; arg : pointer) : foreachnoderesult;
      var
        ctx : pmodrefscan;
        c : byte;
        iswrite : boolean;
        basesym : tsym;
        staticsym : tstaticvarsym;
      begin
        result:=fen_true;
        ctx:=pmodrefscan(arg);
        { once maximally conservative there is nothing left to discover }
        if (ctx^.reads=mr_unknown) and (ctx^.writes=mr_unknown) and
           ctx^.can_trap and not ctx^.smask_exact then
          begin
            result:=fen_norecurse_true;
            exit;
          end;
        iswrite:=([nf_write,nf_modify]*n.flags)<>[];
        case n.nodetype of
          asmn,raisen,tryexceptn,tryfinallyn,onn:
            begin
              ctx^.reads:=mr_unknown;
              ctx^.writes:=mr_unknown;
              ctx^.can_trap:=true;
              ctx^.smask_exact:=false;
            end;
          goton,labeln:
            ctx^.can_trap:=true;
          divn,modn:
            ctx^.can_trap:=true;
          addn,subn,muln,unaryminusn,typeconvn:
            if ([cs_check_overflow,cs_check_range]*n.localswitches)<>[] then
              ctx^.can_trap:=true;
          derefn:
            begin
              { a dereferenced pointer is an unattributable global/heap access }
              ctx^.smask_exact:=false;
              if iswrite then
                ctx^.writes:=mr_unknown
              else
                begin
                  if mr_unknown>ctx^.reads then ctx^.reads:=mr_unknown;
                end;
            end;
          subscriptn:
            begin
              { a field through an implicit object pointer is a heap access; a
                record-value field is covered by its base loadn }
              if assigned(tsubscriptnode(n).left.resultdef) and
                 is_implicit_pointer_object_type(tsubscriptnode(n).left.resultdef) then
                begin
                  ctx^.smask_exact:=false;
                  if iswrite then
                    ctx^.writes:=mr_unknown
                  else if mr_unknown>ctx^.reads then
                    ctx^.reads:=mr_unknown;
                end;
            end;
          vecn:
            begin
              if ([cs_check_overflow,cs_check_range]*n.localswitches)<>[] then
                ctx^.can_trap:=true;
              { a dynamic / open array / string element is heap or aliased
                memory; a static-array element is covered by its base loadn }
              if not assigned(tvecnode(n).left.resultdef) or
                 not is_normal_array(tvecnode(n).left.resultdef) then
                begin
                  ctx^.smask_exact:=false;
                  if iswrite then
                    ctx^.writes:=mr_unknown
                  else if mr_unknown>ctx^.reads then
                    ctx^.reads:=mr_unknown;
                end;
            end;
          assignn:
            begin
              c:=classify_lvalue_base_ex(tassignmentnode(n).left,basesym,staticsym);
              if c>ctx^.writes then ctx^.writes:=c;
              if c=mr_byref then
                record_byref(ctx,basesym,true)
              else if c=mr_unknown then
                record_static(ctx,staticsym,true);
            end;
          inlinen:
            if not pure_inline(tinlinenode(n).inlinenumber) then
              begin
                ctx^.reads:=mr_unknown;
                ctx^.writes:=mr_unknown;
                ctx^.can_trap:=true;
                ctx^.smask_exact:=false;
              end;
          loadn:
            begin
              c:=classify_sym(tloadnode(n).symtableentry);
              if iswrite then
                begin
                  if c>ctx^.writes then ctx^.writes:=c;
                  if c=mr_byref then
                    record_byref(ctx,tloadnode(n).symtableentry,true)
                  else if c=mr_unknown then
                    record_static(ctx,static_of_sym(tloadnode(n).symtableentry),true);
                end
              else
                begin
                  if c>ctx^.reads then ctx^.reads:=c;
                  if c=mr_byref then
                    record_byref(ctx,tloadnode(n).symtableentry,false)
                  else if c=mr_unknown then
                    record_static(ctx,static_of_sym(tloadnode(n).symtableentry),false);
                end;
            end;
          calln:
            fold_call(ctx,tcallnode(n));
          else
            ;
        end;
      end;


    procedure AnalyzeProcModref(pd : tprocdef; code : tnode);
      var
        ctx : tmodrefscan;

      function classname(v : byte) : string;
        begin
          case v of
            mr_none: classname:='nothing';
            mr_byref: classname:='only through by-ref parameters';
            else classname:='unknown-global';
          end;
        end;

      function traptext(b : boolean) : string;
        begin
          if b then traptext:='may trap/raise' else traptext:='cannot trap';
        end;

      { the by-ref per-formal mask, rendered as a formal-index list, so a
        consumer/-OoREPORT reader can see WHICH parameters a by-ref direction
        touches (empty list => none in range; '~' => the mask is not exact and
        every by-ref actual must be assumed touched) }
      function pmasktext(cls : byte; mask : dword) : string;
        var
          i : longint;
        begin
          pmasktext:='';
          if cls<>mr_byref then
            exit;
          if not ctx.pmask_exact then
            begin
              pmasktext:=' [params ~all]';
              exit;
            end;
          for i:=0 to 31 do
            if (mask and (dword(1) shl i))<>0 then
              begin
                if pmasktext='' then pmasktext:=' [params '+tostr(i)
                else pmasktext:=pmasktext+','+tostr(i);
              end;
          if pmasktext='' then pmasktext:=' [params none]'
          else pmasktext:=pmasktext+']';
        end;

      { the per-static set of an mr_unknown direction, rendered as a
        mangled-name list ('~any' when the set is not exact, i.e. the coarse
        "any global" meaning) }
      function smasktext(cls : byte; const setarr : array of ansistring) : string;
        var
          i : longint;
        begin
          smasktext:='';
          if cls<>mr_unknown then
            exit;
          if not ctx.smask_exact then
            begin
              smasktext:=' [statics ~any]';
              exit;
            end;
          if length(setarr)=0 then
            begin
              smasktext:=' [statics none]';
              exit;
            end;
          for i:=0 to high(setarr) do
            begin
              if i=0 then smasktext:=' [statics '+setarr[i]
              else smasktext:=smasktext+','+setarr[i];
            end;
          smasktext:=smasktext+']';
        end;

      begin
        if not assigned(pd) or not assigned(code) then
          exit;
        { a nested routine's summary is never consulted (calls to it are opaque),
          so do not bother analysing it }
        if pd.owner.symtabletype=localsymtable then
          exit;
        { assembler / external bodies: fully conservative but still recorded, so
          callers get a definite (if weak) answer }
        if (po_assembler in pd.procoptions) or (po_external in pd.procoptions) then
          begin
            pd.modref_reads:=mr_unknown;
            pd.modref_writes:=mr_unknown;
            pd.modref_can_trap:=true;
            pd.modref_pmask_exact:=false;
            pd.modref_smask_exact:=false;
            pd.modref_reads_pmask:=0;
            pd.modref_writes_pmask:=0;
            pd.modref_reads_statics:=nil;
            pd.modref_writes_statics:=nil;
            pd.modref_analyzed:=true;
            exit;
          end;
        ctx.pd:=pd;
        ctx.reads:=mr_none;
        ctx.writes:=mr_none;
        ctx.reads_pmask:=0;
        ctx.writes_pmask:=0;
        ctx.pmask_exact:=true;
        ctx.reads_statics:=nil;
        ctx.writes_statics:=nil;
        ctx.smask_exact:=true;
        ctx.can_trap:=false;
        foreachnodestatic(pm_postprocess,code,@modrefscan_node,@ctx);
        pd.modref_reads:=ctx.reads;
        pd.modref_writes:=ctx.writes;
        pd.modref_can_trap:=ctx.can_trap;
        pd.modref_smask_exact:=ctx.smask_exact;
        { the per-formal masks are meaningful for the mr_byref class and, when the
          static sets are exact, also for the by-ref part of an mr_unknown
          direction's footprint; keep them zero otherwise so the ppu image is
          deterministic }
        pd.modref_pmask_exact:=ctx.pmask_exact;
        if (ctx.reads=mr_byref) or ((ctx.reads=mr_unknown) and ctx.smask_exact) then
          pd.modref_reads_pmask:=ctx.reads_pmask
        else
          pd.modref_reads_pmask:=0;
        if (ctx.writes=mr_byref) or ((ctx.writes=mr_unknown) and ctx.smask_exact) then
          pd.modref_writes_pmask:=ctx.writes_pmask
        else
          pd.modref_writes_pmask:=0;
        { the per-static sets are meaningful only for an mr_unknown direction with
          an exact static footprint; keep them empty otherwise }
        if (ctx.reads=mr_unknown) and ctx.smask_exact then
          pd.modref_reads_statics:=copy(ctx.reads_statics)
        else
          pd.modref_reads_statics:=nil;
        if (ctx.writes=mr_unknown) and ctx.smask_exact then
          pd.modref_writes_statics:=copy(ctx.writes_statics)
        else
          pd.modref_writes_statics:=nil;
        pd.modref_analyzed:=true;
        { -OoREPORT: the discovered summary, once, where it first becomes
          available (never per call site) }
        OptRemark(pd.fileinfo,'modref',pd.fullprocname(false)+
          ' mod/ref summary: reads '+classname(ctx.reads)+pmasktext(ctx.reads,ctx.reads_pmask)+
          smasktext(ctx.reads,pd.modref_reads_statics)+
          ', writes '+classname(ctx.writes)+pmasktext(ctx.writes,ctx.writes_pmask)+
          smasktext(ctx.writes,pd.modref_writes_statics)+
          ', '+traptext(ctx.can_trap));
      end;


    { ---- queries ----------------------------------------------------------- }

    function modref_summary_available(pd : tprocdef) : boolean;
      begin
        result:=assigned(pd) and (pd.modref_analyzed or pd.modref_ppu_valid);
      end;


    function modref_pd_can_trap(pd : tprocdef) : boolean;
      begin
        if modref_summary_available(pd) then
          result:=pd.modref_can_trap
        else
          { unknown routine: assume it can trap }
          result:=true;
      end;


    { does the callee's by-ref access in direction FORWRITE reach any
      globally-reachable location at this call site? Uses the per-formal mask
      (only the actuals the callee actually touches) when the summary is exact,
      otherwise every by-ref actual (the coarse fallback). }
    function byref_reaches_global(cn : tcallnode; pd : tprocdef; mask : dword;
        exact, forwrite : boolean) : boolean;
      var
        carry : dword;
        carryexact : boolean;
      begin
        if exact then
          begin
            carry:=0;
            carryexact:=true;
            result:=map_byref_actuals_masked(cn,pd,mask,nil,carry,carryexact)<>mr_none;
          end
        else
          result:=map_byref_actuals(cn,forwrite)<>mr_none;
      end;


    function modref_call_effect(cn : tcallnode; out reads_global, writes_global : boolean) : boolean;
      var
        pd : tprocdef;
      begin
        reads_global:=true;
        writes_global:=true;
        result:=false;
        { must be a resolved direct call with no aggregate-return machinery }
        if call_target_opaque(cn) then
          exit;
        pd:=tprocdef(cn.procdefinition);
        { -OoPURE verdict is authoritative where it holds }
        if proc_is_const(pd) then
          begin
            reads_global:=false;
            writes_global:=false;
            exit(true);
          end;
        if proc_is_pure(pd) then
          begin
            reads_global:=true;
            writes_global:=false;
            exit(true);
          end;
        if (cs_opt_modref in current_settings.optimizerswitches) and
           modref_summary_available(pd) then
          begin
            case pd.modref_writes of
              mr_none: writes_global:=false;
              mr_byref: writes_global:=byref_reaches_global(cn,pd,pd.modref_writes_pmask,pd.modref_pmask_exact,true);
              else writes_global:=true;
            end;
            case pd.modref_reads of
              mr_none: reads_global:=false;
              mr_byref: reads_global:=byref_reaches_global(cn,pd,pd.modref_reads_pmask,pd.modref_pmask_exact,false);
              else reads_global:=true;
            end;
            exit(true);
          end;
      end;


    { true if any by-reference actual the callee touches in direction FORWRITE
      may ALIAS the specific static S at this call site. A by-ref actual whose
      base is a DIFFERENT named static cannot alias S; a caller local / by-value
      base cannot be a static at all; but a base reached through the caller's OWN
      by-ref parameter (it may have been bound to S by the caller's caller) or an
      unattributable deref / heap base could be S, so both are conservative. The
      set of touched actuals is the exact pmask when EXACT, else every by-ref
      actual (mirrors map_byref_actuals / _masked). }
    function byref_may_alias_static(cn : tcallnode; pd : tprocdef; mask : dword;
        exact, forwrite : boolean; s : tstaticvarsym) : boolean;
      var
        para : tcallparanode;
        c : byte;
        basesym : tsym;
        staticsym : tstaticvarsym;
        fidx : longint;
        relevant : boolean;
        sname : ansistring;
      begin
        result:=true;
        sname:=s.mangledname;
        para:=tcallparanode(cn.left);
        while assigned(para) do
          begin
            if assigned(para.parasym) and assigned(para.paravalue) then
              begin
                if exact then
                  begin
                    fidx:=pd_para_index(pd,para.parasym);
                    relevant:=(fidx>=0) and ((mask and (dword(1) shl fidx))<>0);
                  end
                else if forwrite then
                  relevant:=para.parasym.varspez in [vs_var,vs_out]
                else
                  relevant:=para.parasym.varspez in [vs_var,vs_out,vs_const,vs_constref];
                if relevant then
                  begin
                    c:=classify_lvalue_base_ex(para.paravalue,basesym,staticsym);
                    case c of
                      mr_none: ; { caller local / by-value: never a static }
                      mr_byref:
                        exit(true); { caller by-ref param: could be bound to S }
                      else { mr_unknown }
                        if assigned(staticsym) then
                          begin
                            if staticsym.mangledname=sname then
                              exit(true); { the very same static }
                            { a different named static: cannot alias S }
                          end
                        else
                          exit(true); { deref / heap / unattributable: could be S }
                    end;
                  end;
              end;
            para:=tcallparanode(para.nextpara);
          end;
        result:=false;
      end;


    function modref_call_may_access_static(cn : tcallnode; s : tsym; forwrite : boolean) : boolean;
      var
        pd : tprocdef;
        cls : byte;
        pmask : dword;
        sst : tstaticvarsym;
      begin
        result:=true;
        sst:=static_of_sym(s);
        { only a genuine static has a stable mangled-name identity to test }
        if not assigned(sst) then
          exit;
        if not(cs_opt_modref in current_settings.optimizerswitches) then
          exit;
        if call_target_opaque(cn) then
          exit;
        pd:=tprocdef(cn.procdefinition);
        { -OoPURE verdict is authoritative where it holds }
        if proc_is_const(pd) then
          exit(false);
        if proc_is_pure(pd) then
          begin
            { pure: writes nothing, but may read ANY global including S }
            if forwrite then exit(false) else exit(true);
          end;
        if not modref_summary_available(pd) then
          exit;
        if forwrite then
          begin
            cls:=pd.modref_writes;
            pmask:=pd.modref_writes_pmask;
          end
        else
          begin
            cls:=pd.modref_reads;
            pmask:=pd.modref_reads_pmask;
          end;
        case cls of
          mr_none:
            result:=false;
          mr_byref:
            result:=byref_may_alias_static(cn,pd,pmask,pd.modref_pmask_exact,forwrite,sst);
          else { mr_unknown }
            begin
              if not pd.modref_smask_exact then
                exit(true);
              { exact footprint = the per-static set UNION the by-ref pmask
                actuals; S is accessed iff it is in the set or a touched by-ref
                actual may alias it }
              if forwrite then
                result:=static_name_in_set(sst.mangledname,pd.modref_writes_statics)
              else
                result:=static_name_in_set(sst.mangledname,pd.modref_reads_statics);
              if not result then
                result:=byref_may_alias_static(cn,pd,pmask,pd.modref_pmask_exact,forwrite,sst);
            end;
        end;
      end;

end.
