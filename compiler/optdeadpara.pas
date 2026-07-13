{
    Interprocedural dead-parameter elimination (-OoDEADPARA)

    Part (a) of the gcc -fipa-sra port (gcc/ipa-sra.cc): drop the WORK of passing
    a parameter that the callee provably never reads.  Two halves live here:

      * a bottom-up per-routine SUMMARY -- a per-formal REFERENCE bitmap over the
        routine's ordered parameter list (paras): bit N set means paras[N] is
        loaded (read / written / address-taken / passed on) somewhere in the
        routine's own body.  A CLEAR bit therefore means the formal is never
        touched at all, hence its incoming value is dead.  Computed at the
        routine's codegen exactly like -OoPURE / -OoMODREF (callees compile before
        callers) and serialized cross-unit through the shared per-procdef PPU
        optimizer-summary blob (the optsum_deadpara tag).

      * a caller-side REWRITE (Design 2, "argument-evaluation elision"): at a
        resolved DIRECT call whose target has a summary, for every actual bound to
        a provably-dead by-value scalar formal, and only when the actual is itself
        side-effect-free AND non-trapping, replace the actual expression with a
        cheap constant of the same type.  The callee SIGNATURE is unchanged, so
        this is sound cross-unit and even for virtual / exported / address-taken
        callees (the callee is not modified); an indirect / procvar / aggregate-
        return call site is opaque and never rewritten.  The expensive dead
        computation simply disappears from the caller.

    Because FPC is single-pass this never rewrites an already-compiled callee's
    signature -- it is the sound, landable subset of -fipa-sra.  The record-field
    scalarisation half (part (b)) and the WPO-wide variant are NOT implemented
    here.

    SAFETY.  A formal is eligible for elision only when ALL hold: the callee has a
    usable summary and was not disqualified; the formal index is in 0..31 and its
    reference bit is clear; the formal is passed by VALUE (never var/out/const/
    constref -- those may be written back or their address relied upon); the
    formal is an ordinary ORDINAL (integer/enum/boolean/char) type (so a constant
    is trivially synthesised and no managed-type refcount / aggregate copy
    semantics are disturbed); and the formal is NOT hidden (self / parentfp / high
    / funcret / vmt).  The actual must not trap or have side effects
    (might_have_sideeffects(...,[mhs_exceptions]) -- catches calls, div, deref,
    array index, overflow/range-checked and float ops, volatile loads).  A routine
    is DISQUALIFIED from ever having dead formals (whole mask forced to all-set)
    when it is virtual / abstract / message / external / assembler / has an
    inline-asm block / is exported / interrupt / is a nested routine or CONTAINS a
    nested routine (whose body may read this routine's params through parentfp and
    is compiled separately, so this body's tree does not account for the access).

    This module is free software; see the FPC copying conditions.
}
unit optdeadpara;

{$i fpcdefs.inc}

interface

    uses
      globtype,
      node,
      symdef;

    { Compute the per-formal reference bitmap of routine PD from its final node
      tree CODE and record it (pd.deadpara_ref_mask / deadpara_analyzed).
      HASNESTED / FLAGS come from the finishing routine's procinfo so a routine
      that owns nested procedures (or an inline-asm block) is disqualified. }
    procedure AnalyzeProcDeadPara(pd : tprocdef; code : tnode;
      hasnested : boolean; const flags : tprocinfoflags);

    { Rewrite the CALL nodes in CODE: at each resolved direct call whose target
      has a dead by-value scalar formal, replace a side-effect-free, non-trapping
      actual bound to it with a cheap constant.  Returns the number of actuals
      elided (for measurement). }
    function RewriteDeadParaCalls(pd : tprocdef; code : tnode) : longint;

implementation

    uses
      cutils,
      constexp,
      globals,
      symconst,symtype,symsym,
      defutil,
      ncal,ncon,nld,
      nutils,pass_1,
      optutils;


    { index of parameter SYM in PD's ordered parameter list, or -1 when SYM is not
      a parameter of PD or the index does not fit the 32-bit mask.  Derived the
      same deterministic way on both the producer and every consumer (paras is
      reconstructed identically from a ppu), so a mask bit means the same formal
      cross-unit without serialising any symbol identity -- exactly the -OoMODREF
      convention. }
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


    { a formal that must never be considered dead regardless of the body: a hidden
      compiler-synthesised parameter (self / parentfp / high / funcret / vmt / ...)
      carries an implicit ABI meaning a caller cannot drop. }
    function is_hidden_formal(pv : tparavarsym) : boolean;
      begin
        is_hidden_formal:=
          ([vo_is_hidden_para,vo_is_self,vo_is_vmt,vo_is_parentfp,
            vo_is_funcret,vo_is_range_check,vo_is_typinfo_para,vo_is_msgsel,
            vo_is_high_para] * pv.varoptions)<>[];
      end;


    { true when a by-value actual bound to a dead formal of this type can be
      replaced by a synthesised constant without disturbing any copy / refcount /
      aggregate semantics: an ordinary ordinal (integer, enum, boolean, char),
      never a managed or aggregate type. }
    function elidable_formal_type(pv : tparavarsym) : boolean;
      begin
        elidable_formal_type:=
          (pv.varspez=vs_value) and
          not is_hidden_formal(pv) and
          assigned(pv.vardef) and
          is_ordinal(pv.vardef) and
          not is_managed_type(pv.vardef);
      end;


    { ---- summary computation ---------------------------------------------- }

    type
      pdeadparascan = ^tdeadparascan;
      tdeadparascan = record
        pd : tprocdef;
        refmask : dword;
      end;


    function deadparascan_node(var n : tnode; arg : pointer) : foreachnoderesult;
      var
        ctx : pdeadparascan;
        idx : longint;
      begin
        result:=fen_true;
        ctx:=pdeadparascan(arg);
        { every reference to a parameter -- read, write, address-of, by-ref pass,
          subscript / deref base -- ultimately contains a loadn of that parameter
          symbol, so marking every loadn of a formal captures all uses. }
        if (n.nodetype=loadn) and (tloadnode(n).symtableentry is tparavarsym) then
          begin
            idx:=pd_para_index(ctx^.pd,tloadnode(n).symtableentry);
            if idx>=0 then
              ctx^.refmask:=ctx^.refmask or (dword(1) shl idx);
          end;
      end;


    { every hidden formal, and every formal whose index does not fit the mask, is
      marked referenced so it can never be reported dead. }
    procedure mark_untouchable_formals(pd : tprocdef; var refmask : dword);
      var
        i : longint;
        pv : tparavarsym;
      begin
        if not assigned(pd.paras) then
          exit;
        for i:=0 to pd.paras.count-1 do
          begin
            pv:=tparavarsym(pd.paras[i]);
            if (i>31) or is_hidden_formal(pv) or (pv.varspez<>vs_value) then
              begin
                if i<=31 then
                  refmask:=refmask or (dword(1) shl i);
              end;
          end;
      end;


    { a routine that can never expose a droppable parameter to a direct caller. }
    function proc_disqualified(pd : tprocdef; hasnested : boolean;
      const flags : tprocinfoflags) : boolean;
      begin
        proc_disqualified:=
          hasnested or
          (pi_has_assembler_block in flags) or
          (pd.owner.symtabletype=localsymtable) or
          ((po_virtualmethod in pd.procoptions) or
           (po_abstractmethod in pd.procoptions) or
           (po_msgint in pd.procoptions) or
           (po_msgstr in pd.procoptions) or
           (po_external in pd.procoptions) or
           (po_assembler in pd.procoptions) or
           (po_exports in pd.procoptions) or
           (po_public in pd.procoptions) or
           (po_interrupt in pd.procoptions));
      end;


    procedure AnalyzeProcDeadPara(pd : tprocdef; code : tnode;
      hasnested : boolean; const flags : tprocinfoflags);
      var
        ctx : tdeadparascan;

      function masktext(m : dword; np : longint) : string;
        var
          i : longint;
        begin
          masktext:='';
          for i:=0 to np-1 do
            if (i<=31) and ((m and (dword(1) shl i))=0) then
              begin
                if masktext='' then masktext:=tostr(i)
                else masktext:=masktext+','+tostr(i);
              end;
          if masktext='' then masktext:='(none)';
        end;

      begin
        if not assigned(pd) or not assigned(code) or not assigned(pd.paras) then
          exit;
        if proc_disqualified(pd,hasnested,flags) then
          begin
            { every bit set: nothing is ever dead }
            pd.deadpara_ref_mask:=high(dword);
            pd.deadpara_analyzed:=true;
            exit;
          end;
        ctx.pd:=pd;
        ctx.refmask:=0;
        mark_untouchable_formals(pd,ctx.refmask);
        foreachnodestatic(pm_postprocess,code,@deadparascan_node,@ctx);
        pd.deadpara_ref_mask:=ctx.refmask;
        pd.deadpara_analyzed:=true;
        { -OoREPORT: the discovered dead formals, once, where the summary first
          becomes available (never per call site) }
        if cs_opt_report in current_settings.optimizerswitches then
          OptRemark(pd.fileinfo,'deadpara',pd.fullprocname(false)+
            ' never-read by-value scalar parameters: '+masktext(ctx.refmask,pd.paras.count));
      end;


    { ---- caller-side rewrite ---------------------------------------------- }

    { a call target that must be treated as opaque (indirect / procvar / virtual
      dispatch / external / assembler / nested / aggregate-return) -- mirrors the
      -OoMODREF call_target_opaque guard.  A direct call to such a target is never
      rewritten. }
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


    { A callee we refuse to touch at the CALL SITE regardless of its recorded
      summary.  Re-checked here (not only at the callee's analysis) because a flag
      such as po_exports can be set AFTER the callee body was analysed (e.g. a
      program-level `exports` clause) yet is final by the time a caller compiles;
      cross-unit the flags loaded from the ppu are final too. }
    function callee_disqualified(pd : tprocdef) : boolean;
      begin
        callee_disqualified:=
          (po_virtualmethod in pd.procoptions) or
          (po_abstractmethod in pd.procoptions) or
          (po_msgint in pd.procoptions) or
          (po_msgstr in pd.procoptions) or
          (po_external in pd.procoptions) or
          (po_assembler in pd.procoptions) or
          (po_exports in pd.procoptions) or
          (po_public in pd.procoptions) or
          (po_interrupt in pd.procoptions);
      end;


    { formal INDEX of callee CALLEEPD is a provably-dead, elidable by-value scalar. }
    function formal_is_dead(calleepd : tprocdef; index : longint) : boolean;
      begin
        result:=false;
        if (index<0) or (index>31) then
          exit;
        if not(calleepd.deadpara_analyzed or calleepd.deadpara_ppu_valid) then
          exit;
        result:=(calleepd.deadpara_ref_mask and (dword(1) shl index))=0;
      end;


    type
      pdeadpararewrite = ^tdeadpararewrite;
      tdeadpararewrite = record
        callerpd : tprocdef;
        count : longint;
      end;


    function deadpararewrite_node(var n : tnode; arg : pointer) : foreachnoderesult;
      var
        rw : pdeadpararewrite;
        cn : tcallnode;
        calleepd : tprocdef;
        para : tcallparanode;
        idx : longint;
        oldval,newval : tnode;
      begin
        result:=fen_true;
        rw:=pdeadpararewrite(arg);
        if n.nodetype<>calln then
          exit;
        cn:=tcallnode(n);
        if call_target_opaque(cn) then
          exit;
        calleepd:=tprocdef(cn.procdefinition);
        if callee_disqualified(calleepd) then
          exit;
        para:=tcallparanode(cn.left);
        while assigned(para) do
          begin
            if assigned(para.parasym) and assigned(para.paravalue) then
              begin
                idx:=pd_para_index(calleepd,para.parasym);
                oldval:=para.paravalue;
                if (idx>=0) and formal_is_dead(calleepd,idx) and
                   elidable_formal_type(para.parasym) and
                   assigned(oldval.resultdef) and is_ordinal(oldval.resultdef) and
                   (oldval.nodetype<>ordconstn) and
                   not might_have_sideeffects(oldval,[mhs_exceptions]) then
                  begin
                    newval:=cordconstnode.create(0,oldval.resultdef,false);
                    typecheckpass(newval);
                    do_firstpass(newval);
                    para.paravalue:=newval;
                    oldval.free;
                    inc(rw^.count);
                    if cs_opt_report in current_settings.optimizerswitches then
                      OptRemark(cn.fileinfo,'deadpara',
                        'elided evaluation of dead argument #'+tostr(idx)+' to '+
                        calleepd.fullprocname(false));
                  end;
              end;
            para:=tcallparanode(para.nextpara);
          end;
      end;


    function RewriteDeadParaCalls(pd : tprocdef; code : tnode) : longint;
      var
        rw : tdeadpararewrite;
      begin
        result:=0;
        if not assigned(pd) or not assigned(code) then
          exit;
        rw.callerpd:=pd;
        rw.count:=0;
        foreachnodestatic(pm_postprocess,code,@deadpararewrite_node,@rw);
        result:=rw.count;
      end;

end.
