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
      node,ncal,symdef;

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

implementation

    uses
      globtype,globals,
      symconst,symtype,symsym,
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


    { classify the ultimate base of an l-value / addressable expression: what
      memory, in the CURRENT routine's frame, does it denote? (mr_none for a
      non-escaping local / by-value parameter, mr_byref for something reached
      through a by-reference parameter, mr_unknown for a static/global, a pointer
      dereference or anything not recognised) }
    function classify_lvalue_base(t : tnode) : byte;
      begin
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
              exit(classify_sym(tloadnode(t).symtableentry));
            else
              exit(mr_unknown);
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

    type
      pmodrefscan = ^tmodrefscan;
      tmodrefscan = record
        reads : byte;
        writes : byte;
        can_trap : boolean;
      end;

    { fold a callee's summary, mapped through the call's actual arguments, into
      the caller's accumulating summary }
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


    procedure fold_call(ctx : pmodrefscan; cn : tcallnode);
      var
        pd : tprocdef;
        c : byte;
      begin
        if call_target_opaque(cn) then
          begin
            ctx^.reads:=mr_unknown;
            ctx^.writes:=mr_unknown;
            ctx^.can_trap:=true;
            exit;
          end;
        pd:=tprocdef(cn.procdefinition);
        { -OoPURE's stronger verdict stays authoritative where it holds }
        if proc_is_const(pd) then
          { reads nothing, writes nothing, cannot trap: contributes nothing }
          exit;
        if proc_is_pure(pd) then
          begin
            { may read global memory, writes nothing, non-trapping }
            if mr_unknown>ctx^.reads then
              ctx^.reads:=mr_unknown;
            exit;
          end;
        if modref_summary_available(pd) then
          begin
            case pd.modref_writes of
              mr_none: ;
              mr_byref:
                begin
                  c:=map_byref_actuals(cn,true);
                  if c>ctx^.writes then ctx^.writes:=c;
                end;
              else
                ctx^.writes:=mr_unknown;
            end;
            case pd.modref_reads of
              mr_none: ;
              mr_byref:
                begin
                  c:=map_byref_actuals(cn,false);
                  if c>ctx^.reads then ctx^.reads:=c;
                end;
              else
                ctx^.reads:=mr_unknown;
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
      end;


    function modrefscan_node(var n : tnode; arg : pointer) : foreachnoderesult;
      var
        ctx : pmodrefscan;
        c : byte;
        iswrite : boolean;
      begin
        result:=fen_true;
        ctx:=pmodrefscan(arg);
        { once maximally conservative there is nothing left to discover }
        if (ctx^.reads=mr_unknown) and (ctx^.writes=mr_unknown) and ctx^.can_trap then
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
            end;
          goton,labeln:
            ctx^.can_trap:=true;
          divn,modn:
            ctx^.can_trap:=true;
          addn,subn,muln,unaryminusn,typeconvn:
            if ([cs_check_overflow,cs_check_range]*n.localswitches)<>[] then
              ctx^.can_trap:=true;
          derefn:
            if iswrite then
              ctx^.writes:=mr_unknown
            else
              begin
                if mr_unknown>ctx^.reads then ctx^.reads:=mr_unknown;
              end;
          subscriptn:
            begin
              { a field through an implicit object pointer is a heap access; a
                record-value field is covered by its base loadn }
              if assigned(tsubscriptnode(n).left.resultdef) and
                 is_implicit_pointer_object_type(tsubscriptnode(n).left.resultdef) then
                begin
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
                  if iswrite then
                    ctx^.writes:=mr_unknown
                  else if mr_unknown>ctx^.reads then
                    ctx^.reads:=mr_unknown;
                end;
            end;
          assignn:
            begin
              c:=classify_lvalue_base(tassignmentnode(n).left);
              if c>ctx^.writes then ctx^.writes:=c;
            end;
          inlinen:
            if not pure_inline(tinlinenode(n).inlinenumber) then
              begin
                ctx^.reads:=mr_unknown;
                ctx^.writes:=mr_unknown;
                ctx^.can_trap:=true;
              end;
          loadn:
            begin
              c:=classify_sym(tloadnode(n).symtableentry);
              if iswrite then
                begin
                  if c>ctx^.writes then ctx^.writes:=c;
                end
              else if c>ctx^.reads then
                ctx^.reads:=c;
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
            pd.modref_analyzed:=true;
            exit;
          end;
        ctx.reads:=mr_none;
        ctx.writes:=mr_none;
        ctx.can_trap:=false;
        foreachnodestatic(pm_postprocess,code,@modrefscan_node,@ctx);
        pd.modref_reads:=ctx.reads;
        pd.modref_writes:=ctx.writes;
        pd.modref_can_trap:=ctx.can_trap;
        pd.modref_analyzed:=true;
        { -OoREPORT: the discovered summary, once, where it first becomes
          available (never per call site) }
        OptRemark(pd.fileinfo,'modref',pd.fullprocname(false)+
          ' mod/ref summary: reads '+classname(ctx.reads)+
          ', writes '+classname(ctx.writes)+
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
              mr_byref: writes_global:=map_byref_actuals(cn,true)<>mr_none;
              else writes_global:=true;
            end;
            case pd.modref_reads of
              mr_none: reads_global:=false;
              mr_byref: reads_global:=map_byref_actuals(cn,false)<>mr_none;
              else reads_global:=true;
            end;
            exit(true);
          end;
      end;

end.
