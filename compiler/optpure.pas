{
    Interprocedural pure/const function-attribute discovery (-OoPURE)

    Ports the idea of gcc's -fipa-pure-const to FPC.  For each ordinary routine
    compiled in the current unit this pass proves, conservatively, whether the
    routine is

      * "const" : its result depends only on its by-value parameters -- it reads
                  no global/static/threadvar/dereferenced memory and has no side
                  effects, and

      * "pure"  : it may read global memory but never writes it and performs no
                  I/O and no other observable side effect.

    Because a wrong attribute is a miscompile, everything that cannot be proven
    harmless is treated as impure: any write to a global/static/threadvar or
    through a pointer, any I/O, raise, try/except, inline assembler, trapping
    (range/overflow-checked or div/mod) arithmetic, and any call to an
    indirect/virtual/external/method/nested routine or to a routine that is not
    itself proven pure/const.

    Read-only instance methods (the classic  function TFoo.GetX:Integer;begin
    Result:=FX end  accessor) are also eligible, but only in the "pure" flavour:
    a method's result depends on the state referenced through self, so it can
    never be "const" (that would require depending only on by-value arguments).
    A method is proven pure exactly when it writes nothing reachable through self
    (self.field stores are treated as side effects regardless of how self is
    passed -- a by-value class pointer or a by-ref record self), reads only self /
    globals / its read-only parameters, performs no virtual dispatch on self and
    no method call, and calls only proven-pure ordinary routines. Virtual /
    abstract methods and constructors / destructors are excluded. The resulting
    "pure" verdict has the same consumer semantics as an ordinary pure function:
    -OoGVNPRE value-numbers the call as a memory reader whose result is
    invalidated by any intervening store or call (so a field write between two
    getter calls, or a call across them, correctly prevents commoning), so no new
    ppu summary flavour is needed -- a pure method serializes exactly like a pure
    function (pure bit set, const bit clear).

    The per-routine summary is stored on the tprocdef.  A summary records the
    intrinsic facts of the body plus the list of ordinary routines it calls; the
    actual pure/const verdict is computed on demand with a greatest-fixpoint DFS
    over that call graph, so mutually-recursive SCCs whose only impurity would be
    the recursion itself are still proven.  The raw facts/callee list are
    transient (current-unit only), but the DERIVED pure/const verdict is
    serialized into the ppu via the shared per-procdef optimizer-summary
    mechanism (tprocdef.write_optimizer_summary): a routine loaded from a used
    unit carries its resolved verdict as two booleans (pure_ppu_valid), so
    cross-unit callers consult it instead of treating it as impure.

    This module is free software; see the FPC copying conditions.
}
unit optpure;

{$i fpcdefs.inc}

interface

    uses
      node,symdef;

    { analyse the (final) node tree CODE of routine PD and fill in its
      transient purity summary (pd.pure_analyzed etc.) }
    procedure AnalyzeProcPurity(pd : tprocdef; code : tnode);

    { on-demand verdicts over the summaries collected so far. A routine that has
      not been analysed (e.g. loaded from another unit) is treated as impure. }
    function proc_is_pure(pd : tprocdef) : boolean;
    function proc_is_const(pd : tprocdef) : boolean;
    { -OoPURE nothrow attribute, INDEPENDENT of purity: the routine (and every
      routine it calls) provably cannot raise an exception or trap. Holds for
      many IMPURE routines too (e.g. a routine that only writes a global). }
    function proc_is_nothrow(pd : tprocdef) : boolean;
    { writes no memory (may read globals, MAY trap): "pure minus the nothrow
      requirement". proc_is_pure = proc_is_mempure and proc_is_nothrow. }
    function proc_is_mempure(pd : tprocdef) : boolean;

implementation

    uses
      globtype,globals,verbose,
      cclasses,
      symbase,symtype,symconst,symsym,symtable,
      defutil,
      nutils,ncal,nld,nmem,ninl,ncnv,
      optutils,
      compinnr;

    type
      ppurescan = ^tpurescan;
      tpurescan = record
        pd : tprocdef;
        { MEMORY / side-effect impurity (a global write, addr-taken, goto,
          impure intrinsic, unknown call ...) -- but NOT trapping, which is
          tracked separately in cantrap. kills pure/const/mempure. }
        impure : boolean;
        { can raise an exception or trap (div/mod, checked arithmetic, a pointer
          dereference that may fault, inline asm, an unknown/indirect call, a
          raise / try..except) -- tracked INDEPENDENTLY of memory impurity so a
          nothrow verdict is available even for a memory-impure routine. kills
          pure/const (folded back in) and nothrow, but NOT mempure. }
        cantrap : boolean;
        readsglobal : boolean;
        { -OoREPORT: the first (dominant) intrinsic-impurity cause found, so the
          remark can name a concrete why-not. Purely diagnostic. }
        reason : ansistring;
      end;

    { inline intrinsics that are genuinely side-effect-free, non-trapping value
      computations. Anything not listed here is treated as impure (safe: at
      worst we miss an optimisation). Deliberately excludes length/high/low
      (memory reads), setlength/new/dispose/write/read/inc/dec (side effects),
      etc. }
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


    { classify the ultimate base of an l-value: does writing to it write global
      or otherwise externally-observable memory? Returns true if the write is a
      side effect (global/static/threadvar, by-ref parameter, pointer deref, or
      anything not recognised as a plain local), false for a write to a local /
      by-value parameter / simple function result. }
    function lvalue_write_is_side_effect(t : tnode) : boolean;
      var
        sym : tsym;
      begin
        result:=true;
        while assigned(t) do
          case t.nodetype of
            typeconvn:
              t:=ttypeconvnode(t).left;
            subscriptn:
              t:=tsubscriptnode(t).left;
            vecn:
              { a[i]: descend to the base; a deref/global base is caught there,
                a local static array base ends at its loadn }
              t:=tvecnode(t).left;
            temprefn:
              { a compiler-created temporary (ttempcreatenode storage) is local,
                non-escaping stack storage -- e.g. the from/to bound temps that
                ConvertForLoops synthesizes when it lowers a counted for-loop to a
                while-loop before this pass runs. A store to such a temp is never
                externally observable, so it does not disqualify const/pure. (A
                store THROUGH it -- temp^ := ... -- is a derefn and still caught
                above; temp.field / temp[i] descend here to the same verdict on
                local temp storage.) }
              exit(false);
            derefn:
              exit(true);
            loadn:
              begin
                sym:=tloadnode(t).symtableentry;
                if sym is tstaticvarsym then
                  exit(true)
                else if sym is tparavarsym then
                  begin
                    { self is a reference to the object: any store reachable
                      through it (self.field := ...) writes externally-observable
                      state, whether self is a by-value class pointer (vs_value)
                      or a by-ref record/object self (vs_var/constref). Treat it
                      as a side effect unconditionally, so a read-only method
                      that keeps this out of its body can still be proven pure. }
                    if vo_is_self in tparavarsym(sym).varoptions then
                      exit(true);
                    if (tparavarsym(sym).varspez in [vs_var,vs_out,vs_constref]) and
                       not(vo_is_funcret in tparavarsym(sym).varoptions) then
                      exit(true)
                    else
                      exit(false);
                  end
                else if sym is tlocalvarsym then
                  exit(false)
                else
                  exit(true);
              end;
            else
              exit(true);
          end;
      end;


    { a call to a routine with any of these properties can never be proven
      pure/const and must not even be added to the callee list }
    function procoptions_conflict(pd : tprocdef) : boolean;
      begin
        result:=
          (po_external in pd.procoptions) or
          (po_virtualmethod in pd.procoptions) or
          (po_abstractmethod in pd.procoptions) or
          (po_assembler in pd.procoptions) or
          assigned(pd.struct) or
          (pd.owner.symtabletype=localsymtable);
      end;


    { -OoREPORT: a short human phrase for the impurity a node introduced, used
      only to build the diagnostic remark's why-not text (never a decision) }
    function purity_reason_for(n : tnode) : ansistring;
      begin
        case n.nodetype of
          asmn:
            result:='contains inline assembler';
          raisen,tryexceptn,tryfinallyn,onn:
            result:='uses exceptions';
          goton,labeln:
            result:='contains a goto/label';
          addrn:
            result:='takes the address of something';
          divn,modn:
            result:='may trap on division';
          assignn,loadn,derefn,subscriptn,vecn,addn,subn,muln,unaryminusn,typeconvn:
            result:='writes global/static state or has a checked-arithmetic side effect';
          inlinen:
            result:='calls a non-pure intrinsic (I/O, allocation, length/setlength, ...)';
          calln:
            result:='calls an indirect / virtual / external routine';
          else
            result:='has a side effect';
        end;
      end;


    function purescan_node(var n : tnode; arg : pointer) : foreachnoderesult;
      var
        ctx : ppurescan;
        sym : tsym;
        pd : tabstractprocdef;
        iswrite : boolean;
        para : tcallparanode;
      begin
        result:=fen_true;
        ctx:=ppurescan(arg);
        { nothing more to learn once BOTH facts are already set (memory-impure
          AND may-trap): the subtree can neither un-set them nor add a verdict.
          readsglobal is irrelevant once impure (const already lost). }
        if ctx^.impure and ctx^.cantrap then
          begin
            result:=fen_norecurse_true;
            exit;
          end;
        case n.nodetype of
          asmn:
            { inline asm is opaque: may write memory AND trap }
            begin ctx^.impure:=true; ctx^.cantrap:=true; end;
          raisen,tryexceptn,tryfinallyn,onn:
            { exception machinery: a trap, but no direct memory side effect
              (child stores are scanned as their own nodes) }
            ctx^.cantrap:=true;
          goton,labeln,addrn:
            { control complexity / addr-taken: keeps the routine out of
              pure/const as before, but cannot itself raise/trap }
            ctx^.impure:=true;
          divn,modn:
            { division may trap (div by zero) -> not safe to speculate }
            ctx^.cantrap:=true;
          addn,subn,muln,unaryminusn,typeconvn,vecn:
            begin
              if ([cs_check_overflow,cs_check_range]*n.localswitches)<>[] then
                ctx^.cantrap:=true;
              if n.nodetype=vecn then
                ctx^.readsglobal:=true;
            end;
          subscriptn:
            ctx^.readsglobal:=true;
          derefn:
            begin
              { a pointer dereference may fault (nil / wild pointer): a trap for
                nothrow/speculation purposes, whether a read or a write; a write
                is additionally a memory side effect }
              ctx^.cantrap:=true;
              if ([nf_write,nf_modify]*n.flags)<>[] then
                ctx^.impure:=true
              else
                ctx^.readsglobal:=true;
            end;
          assignn:
            if lvalue_write_is_side_effect(tassignmentnode(n).left) then
              ctx^.impure:=true;
          inlinen:
            case tinlinenode(n).inlinenumber of
              in_succ_x,in_pred_x:
                { succ/pred is a non-trapping +1/-1 value computation UNLESS
                  range/overflow checking is on (then it may trap at the type
                  boundary). }
                if ([cs_check_overflow,cs_check_range]*n.localswitches)<>[] then
                  ctx^.cantrap:=true;
              in_inc_x,in_dec_x:
                { inc/dec mutates its target argument in place. That is a memory
                  side effect only if the target is externally observable;
                  mutating a plain LOCAL (or a compiler temp) is not. Checked
                  inc/dec may trap. Only the write-flagged argument matters. }
                begin
                  if ([cs_check_overflow,cs_check_range]*n.localswitches)<>[] then
                    ctx^.cantrap:=true;
                  para:=tcallparanode(tinlinenode(n).left);
                  while assigned(para) do
                    begin
                      if (assigned(para.left)) and
                         (([nf_write,nf_modify]*para.left.flags)<>[]) and
                         lvalue_write_is_side_effect(para.left) then
                        ctx^.impure:=true;
                      para:=tcallparanode(para.right);
                    end;
                end;
              else
                if not pure_inline(tinlinenode(n).inlinenumber) then
                  { unknown intrinsic (I/O, allocation, ...): may write memory
                    AND may raise (e.g. an I/O error, out-of-memory) }
                  begin ctx^.impure:=true; ctx^.cantrap:=true; end;
            end;
          loadn:
            begin
              sym:=tloadnode(n).symtableentry;
              iswrite:=([nf_write,nf_modify]*n.flags)<>[];
              if sym is tstaticvarsym then
                begin
                  if iswrite then
                    ctx^.impure:=true
                  else
                    ctx^.readsglobal:=true;
                end
              else if sym is tparavarsym then
                begin
                  if (tparavarsym(sym).varspez in [vs_var,vs_out,vs_constref]) and
                     not(vo_is_funcret in tparavarsym(sym).varoptions) then
                    begin
                      if iswrite then
                        ctx^.impure:=true
                      else
                        ctx^.readsglobal:=true;
                    end;
                  { by-value / const-by-value / funcret parameter: local copy }
                end
              else if (sym is tlocalvarsym) or (sym is tconstsym) or
                      (sym is tprocsym) or (sym is ttypesym) then
                { local / true constant / routine address / type: harmless }
              else
                { unknown symbol kind (absolute var, with-field, ...): be safe }
                begin
                  if iswrite then
                    ctx^.impure:=true
                  else
                    ctx^.readsglobal:=true;
                end;
            end;
          calln:
            begin
              pd:=tcallnode(n).procdefinition;
              if not assigned(pd) or not(pd is tprocdef) then
                { indirect / procvar call: unknown target (may write and raise) }
                begin ctx^.impure:=true; ctx^.cantrap:=true; end
              else if assigned(tcallnode(n).methodpointer) then
                { dynamically-dispatched / method-through-pointer call }
                begin ctx^.impure:=true; ctx^.cantrap:=true; end
              else if (procoptions_conflict(tprocdef(pd))) then
                begin ctx^.impure:=true; ctx^.cantrap:=true; end
              else
                begin
                  { direct call to an ordinary routine: record the dependency,
                    the fixpoint decides whether it keeps us pure/const/nothrow }
                  SetLength(ctx^.pd.pure_callees,Length(ctx^.pd.pure_callees)+1);
                  ctx^.pd.pure_callees[High(ctx^.pd.pure_callees)]:=tprocdef(pd);
                end;
            end;
          else
            ;
        end;
        if (ctx^.impure or ctx^.cantrap) and (ctx^.reason='') then
          ctx^.reason:=purity_reason_for(n);
        if ctx^.impure and ctx^.cantrap then
          result:=fen_norecurse_true;
      end;


    { does the routine's signature/shape make it eligible at all? We restrict to
      standalone (non-method, non-nested) routines with a simple scalar/pointer
      result -- so the result lives in a local -- whose parameters are read-only:
      simple by-value parameters (a plain local read) or const/constref parameters
      (read-only, cannot write caller memory). const/constref additionally accepts
      unmanaged record/array/set aggregates, so array/field-reading const helpers
      qualify (their reads are pure memory reads). Read-only methods are also
      eligible (see proc_eligible): self is treated as a read-only reference and
      any store through it is a side effect. }
    function simple_purity_type(def : tdef) : boolean;
      begin
        result:=assigned(def) and (def.typ in [orddef,enumdef,floatdef,pointerdef]);
      end;


    { a type acceptable for a read-only (const / constref) by-reference parameter:
      besides the simple scalars we also accept records, fixed arrays and sets, so
      that array/field-reading const helpers (which read through the caller's
      storage but never write it) become eligible. Managed (ref-counted / init-
      table) aggregates are excluded because their implicit init/finalisation is a
      hidden side effect we do not model. }
    function const_readable_type(def : tdef) : boolean;
      begin
        result:=false;
        if not assigned(def) then
          exit;
        if simple_purity_type(def) then
          exit(true);
        if def.typ in [recorddef,arraydef,setdef] then
          result:=not is_managed_type(def);
      end;


    function proc_eligible(pd : tprocdef) : boolean;
      var
        i : longint;
        pv : tparavarsym;
      begin
        result:=false;
        { disqualifiers shared by plain routines and methods. Unlike
          procoptions_conflict (the strict CALLEE filter, which rejects every
          method) we allow a routine that lives in a struct here, provided it is
          a non-virtual, non-abstract instance/class/static method that is not a
          constructor/destructor: the body scan then proves it writes nothing
          through self. Virtual/abstract dispatch on the routine itself is out
          (a caller cannot know the concrete body). }
        if (po_external in pd.procoptions) or
           (po_virtualmethod in pd.procoptions) or
           (po_abstractmethod in pd.procoptions) or
           (po_assembler in pd.procoptions) or
           (pd.owner.symtabletype=localsymtable) then
          exit;
        if assigned(pd.struct) and
           (pd.proctypeoption in [potype_constructor,potype_destructor]) then
          exit;
        if not simple_purity_type(pd.returndef) then
          exit;
        for i:=0 to pd.paras.count-1 do
          begin
            pv:=tparavarsym(pd.paras[i]);
            if vo_is_self in pv.varoptions then
              { self: a read-only reference. Writes through it are rejected by
                the body scan (lvalue_write_is_side_effect); reads through it are
                pure memory reads (so a method is at best pure, never const). }
              continue;
            if vo_is_hidden_para in pv.varoptions then
              { any other hidden parameter (vmt, high, framepointer, ...): stay
                conservative and bail }
              exit;
            case pv.varspez of
              vs_value:
                { by-value: the routine owns a private local copy. Keep it simple
                  so no managed-copy finalisation sneaks in as a side effect. }
                if not simple_purity_type(pv.vardef) then
                  exit;
              vs_const,vs_constref:
                { read-only parameter. A simple const is a by-value local read; an
                  aggregate const/constref is a pure read through caller storage.
                  Writes to it are impossible (language) / caught as impure. }
                if not const_readable_type(pv.vardef) then
                  exit;
              else
                { vs_var / vs_out: writable alias into caller storage -> impure }
                exit;
            end;
          end;
        result:=true;
      end;


    procedure AnalyzeProcPurity(pd : tprocdef; code : tnode);
      var
        ctx : tpurescan;
      begin
        if not assigned(pd) or not assigned(code) then
          exit;
        pd.pure_callees:=nil;
        pd.pure_reads_global:=false;
        pd.pure_qtoken:=0;
        pd.pure_qresult:=0;
        if not proc_eligible(pd) then
          begin
            pd.pure_intrinsic_impure:=true;
            pd.pure_can_trap:=true;
            pd.pure_analyzed:=true;
            { -OoREPORT: a routine tuning users might expect kept out of a loop
              (LICM) but that the analysis cannot even consider }
            OptRemark(pd.fileinfo,'pure',pd.fullprocname(false)+
              ' not analyzed: ineligible signature (non-simple result, or a'+
              ' writable/managed/hidden parameter, or method/virtual dispatch)');
            exit;
          end;
        ctx.pd:=pd;
        ctx.impure:=false;
        ctx.cantrap:=false;
        ctx.readsglobal:=false;
        ctx.reason:='';
        foreachnodestatic(pm_postprocess,code,@purescan_node,@ctx);
        pd.pure_intrinsic_impure:=ctx.impure;
        pd.pure_can_trap:=ctx.cantrap;
        pd.pure_reads_global:=ctx.readsglobal;
        pd.pure_analyzed:=true;
        { -vh diagnostic: report the discovered verdict once, here, at the point
          it is first available (not per call site), respecting -vh gating. const
          is the stronger verdict (implies pure), so report only the strongest;
          the nothrow verdict is ORTHOGONAL and reported on its own line (so an
          impure-but-nothrow routine still gets a nothrow hint). }
        if proc_is_const(pd) then
          MessagePos1(pd.fileinfo,cg_h_proc_const,pd.fullprocname(false))
        else if proc_is_pure(pd) then
          MessagePos1(pd.fileinfo,cg_h_proc_pure,pd.fullprocname(false));
        if proc_is_nothrow(pd) then
          MessagePos1(pd.fileinfo,cg_h_proc_nothrow,pd.fullprocname(false));
        { -OoREPORT: the same verdict, plus the concrete why-not when neither
          verdict holds, routed through the optimization-remarks facility. The
          fixpoint (proc_is_pure/const) is the final answer -- when the body is
          intrinsically clean but a callee spoils it, name that instead. }
        if proc_is_const(pd) then
          OptRemark(pd.fileinfo,'pure',pd.fullprocname(false)+
            ' proven const (result depends only on its by-value parameters)')
        else if proc_is_pure(pd) then
          OptRemark(pd.fileinfo,'pure',pd.fullprocname(false)+
            ' proven pure (reads but never writes global state)')
        else if ctx.impure or ctx.cantrap then
          OptRemark(pd.fileinfo,'pure',pd.fullprocname(false)+
            ' not pure/const: '+ctx.reason)
        else
          OptRemark(pd.fileinfo,'pure',pd.fullprocname(false)+
            ' not pure/const: calls a routine not provably pure/const');
        { orthogonal nothrow remark: observable even for an impure routine }
        if proc_is_nothrow(pd) then
          OptRemark(pd.fileinfo,'pure',pd.fullprocname(false)+
            ' proven nothrow (cannot raise or trap)');
      end;


    { ---- on-demand greatest-fixpoint verdict ---------------------------------

      Query semantics (const, and analogously pure):
          const(pd) = pd analysed
                      and not pd.pure_intrinsic_impure
                      and not pd.pure_reads_global
                      and const(c) for every callee c

      A per-query token distinguishes results/marks of the current query from
      stale ones. pure_qresult: 0 = currently on the DFS stack (assume pure
      optimistically to break cycles), 1 = decided pure/const, 2 = decided
      impure. False strictly dominates and short-circuits, so a member of an SCC
      is only ever decided pure/const when the whole SCC genuinely is. }

    var
      pure_query_token : cardinal = 0;

    { want: 0=pure, 1=const, 2=nothrow, 3=mempure. The self-fail predicate and
      the cross-unit leaf bit differ per mode; a routine has the verdict iff it
      does not self-fail AND every callee also has it (greatest fixpoint). }
    function dfs_pure(pd : tprocdef; token : cardinal; want : byte) : boolean;
      var
        i : longint;
        r,selffail : boolean;
      begin
        if not assigned(pd) then
          exit(false);
        { a routine read from another unit's ppu carries its already-resolved
          cross-unit verdicts as ready-made booleans (shared PPU optimizer
          summary): treat it as a leaf with that verdict instead of re-deriving
          its call graph (which is not available here). }
        if pd.pure_ppu_valid then
          case want of
            1: exit(pd.pure_ppu_is_const);
            2: exit(pd.pure_ppu_is_nothrow);
            3: exit(pd.pure_ppu_is_mempure);
            else exit(pd.pure_ppu_is_pure);
          end;
        if not pd.pure_analyzed then
          exit(false);
        if pd.pure_qtoken=token then
          begin
            case pd.pure_qresult of
              1: exit(true);
              2: exit(false);
              else exit(true); { on stack: optimistic }
            end;
          end;
        pd.pure_qtoken:=token;
        pd.pure_qresult:=0; { visiting }
        case want of
          1: selffail:=pd.pure_intrinsic_impure or pd.pure_can_trap or pd.pure_reads_global;
          2: selffail:=pd.pure_can_trap;
          3: selffail:=pd.pure_intrinsic_impure;
          else selffail:=pd.pure_intrinsic_impure or pd.pure_can_trap;
        end;
        if selffail then
          begin
            pd.pure_qresult:=2;
            exit(false);
          end;
        r:=true;
        for i:=0 to High(pd.pure_callees) do
          if not dfs_pure(pd.pure_callees[i],token,want) then
            begin
              r:=false;
              break;
            end;
        if r then
          pd.pure_qresult:=1
        else
          pd.pure_qresult:=2;
        result:=r;
      end;


    function proc_is_pure(pd : tprocdef) : boolean;
      begin
        inc(pure_query_token);
        result:=dfs_pure(pd,pure_query_token,0);
      end;


    function proc_is_const(pd : tprocdef) : boolean;
      begin
        inc(pure_query_token);
        result:=dfs_pure(pd,pure_query_token,1);
      end;


    function proc_is_nothrow(pd : tprocdef) : boolean;
      begin
        inc(pure_query_token);
        result:=dfs_pure(pd,pure_query_token,2);
      end;


    function proc_is_mempure(pd : tprocdef) : boolean;
      begin
        inc(pure_query_token);
        result:=dfs_pure(pd,pure_query_token,3);
      end;


    { write-time hook consulted by tprocdef.ppuwrite to persist a routine's
      final pure/const/nothrow/mempure verdicts into its ppu optimizer summary.
      want: 0=pure, 1=const, 2=nothrow, 3=mempure. }
    function purity_verdict_hook(pd : tprocdef; want : byte) : boolean;
      begin
        case want of
          1: result:=proc_is_const(pd);
          2: result:=proc_is_nothrow(pd);
          3: result:=proc_is_mempure(pd);
          else result:=proc_is_pure(pd);
        end;
      end;

initialization
  proc_query_purity_verdict:=@purity_verdict_hook;
end.
