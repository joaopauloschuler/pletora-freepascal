{
    Compile-time evaluation of calls to proven-CONST routines (-OoCONSTEVAL)

    When a resolved DIRECT call targets a routine that -OoPURE has proven
    "const" (its result depends only on its by-value parameters -- see
    compiler/optpure.pas) AND every actual argument is a compile-time ordinal
    constant, this pass interprets the callee's stashed body in a small bounded
    evaluator and replaces the whole call node with the computed literal.  This
    is the effect gcc obtains from inlining + IPA-CP/ccp constant folding and
    that D/C++ expose as CTFE/constexpr; neither stock FPC nor Delphi folds a
    user-function call at compile time.

    How the body is recovered (FPC is single-pass with immediate code
    generation -- a routine is parsed and code-generated the moment its body is
    read, then its tree is freed):

      * intra-unit: a deep copy of the callee's type-checked (pre-firstpass)
        body is stashed as a template the moment it is parsed but before it is
        first-passed and code-generated (consteval_stash_candidate), exactly
        like optipacp.  Callees are always compiled before their callers, so
        when a later caller's call site is processed the callee body -- and its
        already-resolved const verdict -- are both available.

      * cross-unit: an eligible routine reachable from another unit (an
        interface routine, or one already inline) has its body RETAINED as
        inlininginfo -- the vehicle cross-unit inlining already streams into the
        PPU -- WITHOUT po_inline (ordinary call/inlining behaviour unchanged).
        A caller in a USED unit recovers that streamed body and interprets it;
        the const verdict itself rides the shared optsum_pure PPU summary
        (tprocdef.pure_ppu_is_const).

    The evaluator:
      * locals and value parameters form a value environment (keyed on their
        symbol); assignment, if / case / for / while / repeat, break / continue
        / exit and nested calls to OTHER proven-const routines (under a
        recursion cap) are interpreted; a hard step budget makes a long-running
        body degrade to "not folded" instead of hanging compilation.
      * ordinal arithmetic is evaluated with the exact two's-complement
        semantics of the generated code -- every intermediate is truncated to
        the node's own (type-checked) result type, so the fold is bit-identical
        to what codegen would have produced.
      * single/double float arithmetic (add/sub/mul, unary minus, comparison,
        sqr, abs, int->float and single<->double conversion) is evaluated in a
        double and ROUNDED to the node's own precision at every step -- a single
        op rounds to single per step -- reproducing the per-operation rounding
        SSE codegen performs, so a float fold is bit-for-bit identical too
        (add/sub/mul of two singles are exact in a double, hence double-then-
        round is the correctly-rounded single result). extended/comp/currency
        are NOT modelled and make the site refuse.
      * still out of scope (the site refuses -- always sound, only an
        optimisation missed): set, array, record, string, pointer, taking an
        address, div/mod and float division (a proven-const routine never
        contains integer div/mod -- optpure treats it as trapping -- and float
        division is excluded to avoid single double-rounding), sqrt/pi, or any
        node the evaluator does not model.

    Distinct from -OoIPACP (clones a specialized body but still emits a call
    that runs at run time) and from GVN-PRE (reuses a run-time-computed value,
    never a literal).  Opt-in via -OoCONSTEVAL; NOT part of the -O4 defaults --
    a wrong fold is a miscompile.  -OoREPORT emits a remark per folded site and
    per refusal (with reason).

    This module is free software; see the FPC copying conditions.
}
unit optconsteval;

{$i fpcdefs.inc}

interface

    uses
      cclasses,
      globtype,node,symdef;

    { Reset the per-module body stash.  Cheap; only clears on module change. }
    procedure consteval_module_check;

    { If PD has a const-eligible signature, stash a deep copy of its type-checked
      (pre-firstpass) body CODE as a template for later callers.  Must be called
      on the final node tree BEFORE generate_code_tree lowers/frees it. }
    procedure consteval_stash_candidate(pd : tprocdef; code : tnode);

    { True when PD (a routine in the unit being compiled) should have its body
      retained as inlininginfo so it is streamed into the PPU as a cross-unit
      const-eval template (an interface routine, or one already inline). }
    function consteval_crossunit_retain_candidate(pd : tprocdef; code : tnode;
      piflags : tprocinfoflags; hasnested : boolean) : boolean;

    { Scan CALLERPD's body CODE for direct calls to a proven-const routine whose
      every actual is a compile-time ordinal constant; interpret the callee body
      and, on success, replace the call node with the computed literal. }
    procedure consteval_process_calls(callerpd : tprocdef; var code : tnode);

implementation

    uses
      globals,cutils,constexp,verbose,fmodule,
      symconst,symbase,symtype,symsym,symtable,
      defutil,pass_1,
      nbas,nld,ncal,ncon,ncnv,nflw,nset,ninl,nutils,
      compinnr,
      optpure,optutils;

    const
      { do not stash/interpret a body larger than this many nodes }
      consteval_body_budget = 800;
      { hard evaluation step budget: a longer run degrades to "not folded" }
      consteval_step_budget = 300000;
      { nested proven-const call recursion cap }
      consteval_depth_cap = 256;

    { ---- per-module body stash --------------------------------------------- }

    type
      tcestash = class
        calleepd : tprocdef;
        body     : tnode;   { deep copy: typechecked, NOT firstpassed }
        destructor destroy; override;
      end;

    var
      cur_module : pointer = nil;
      stashlist  : TFPObjectList = nil;   { of tcestash }

    destructor tcestash.destroy;
      begin
        if assigned(body) then
          body.free;
        inherited destroy;
      end;

    procedure consteval_clear;
      begin
        if assigned(stashlist) then
          begin
            stashlist.free;
            stashlist:=nil;
          end;
      end;

    procedure consteval_module_check;
      begin
        if cur_module<>pointer(current_module) then
          begin
            consteval_clear;
            cur_module:=pointer(current_module);
            stashlist:=TFPObjectList.create(true);
          end;
      end;

    { ---- structural eligibility -------------------------------------------- }

    { a scalar type the value environment can hold as an ordinal: any ordinal
      (integer/enum/boolean/char). }
    function ordinal_scalar(def : tdef) : boolean;
      begin
        result:=assigned(def) and is_ordinal(def);
      end;

    { a float type the evaluator can model: single or double ONLY.  extended /
      comp / currency are excluded (their codegen precision/semantics -- 80-bit
      x87 vs SSE, fixed-point currency -- are not what this double-based
      evaluator reproduces bit-for-bit). }
    function foldable_float(def : tdef) : boolean;
      begin
        result:=assigned(def) and (is_single(def) or is_double(def));
      end;

    { a scalar the value environment can hold: an ordinal or a foldable float }
    function foldable_scalar(def : tdef) : boolean;
      begin
        result:=ordinal_scalar(def) or foldable_float(def);
      end;

    { does PD's signature make it a plausible const-eval target at all?  A
      standalone (non-method, non-nested) routine with an ordinal/single/double
      result whose visible parameters are by-value/const ordinals or floats.
      This is only a cheap screen; the authoritative const verdict comes from
      optpure at use time. }
    function proc_sig_eligible(pd : tprocdef) : boolean;
      var
        i : longint;
        pv : tparavarsym;
      begin
        result:=false;
        if not assigned(pd) then
          exit;
        if not(pd.proctypeoption in [potype_procedure,potype_function]) then
          exit;
        if assigned(pd.struct) then
          exit;
        if pd.parast.symtablelevel>normal_function_level then
          exit;
        if [df_generic,df_specialization]*pd.defoptions<>[] then
          exit;
        if ([po_external,po_assembler,po_interrupt,po_varargs]*pd.procoptions)<>[] then
          exit;
        if not foldable_scalar(pd.returndef) then
          exit;
        for i:=0 to pd.paras.count-1 do
          begin
            pv:=tparavarsym(pd.paras[i]);
            if vo_is_hidden_para in pv.varoptions then
              exit;
            if not(pv.varspez in [vs_value,vs_const]) then
              exit;
            if not foldable_scalar(pv.vardef) then
              exit;
          end;
        result:=true;
      end;

    procedure consteval_stash_candidate(pd : tprocdef; code : tnode);
      var
        stash : tcestash;
      begin
        if not assigned(pd) or not assigned(code) then
          exit;
        consteval_module_check;
        if not proc_sig_eligible(pd) then
          exit;
        if node_count(code,consteval_body_budget)>=consteval_body_budget then
          exit;
        stash:=tcestash.create;
        stash.calleepd:=pd;
        stash.body:=code.getcopy;
        stashlist.add(stash);
      end;

    function consteval_crossunit_retain_candidate(pd : tprocdef; code : tnode;
      piflags : tprocinfoflags; hasnested : boolean) : boolean;
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
        { only routines reachable from another unit are worth streaming: an
          interface (globalsymtable) routine, or a unit-private one already
          inline (its tree is streamed anyway) }
        if not((pd.owner.symtabletype=globalsymtable) or
               (po_inline in pd.procoptions)) then
          exit;
        if not proc_sig_eligible(pd) then
          exit;
        result:=node_count(code,consteval_body_budget)<consteval_body_budget;
      end;

    function find_stash(pd : tprocdef) : tnode;
      var
        i : longint;
      begin
        result:=nil;
        if not assigned(stashlist) then
          exit;
        for i:=0 to stashlist.count-1 do
          if tcestash(stashlist[i]).calleepd=pd then
            exit(tcestash(stashlist[i]).body);
      end;

    { the body to interpret for PD: the intra-unit stash, or a used unit's
      PPU-streamed inline body }
    function get_callee_body(pd : tprocdef) : tnode;
      begin
        result:=find_stash(pd);
        if assigned(result) then
          exit;
        if pd.owner.iscurrentunit then
          exit;
        if pd.has_inlininginfo and assigned(pd.inlininginfo) then
          result:=pd.inlininginfo^.code;
      end;

    { ---- bounded evaluator -------------------------------------------------- }

    type
      { evaluation state shared across nested-call frames }
      pceshared = ^tceshared;
      tceshared = record
        steps   : longint;
        failed  : boolean;
        reason  : ansistring;
      end;

      tflow = (fl_normal, fl_break, fl_continue, fl_exit);

      { a scalar value in the evaluator: either an ordinal (exact two's-complement
        tconstexprint) or an IEEE float held in a double.  A float value is ALWAYS
        kept already rounded to the precision of the node/def it came from -- a
        single-typed value is a single-representable number stored in the double
        -- so that every step is bit-identical to codegen (which rounds each SSE
        single/double op to the operand type).  Only single/double are modelled;
        extended/currency/comp make the site refuse. }
      tcevalkind = (cev_ord, cev_flt);
      tceval = record
        kind : tcevalkind;
        ord  : tconstexprint;   { valid when kind=cev_ord }
        flt  : double;          { valid when kind=cev_flt (single values pre-rounded) }
      end;

      { one call frame: a value environment plus the accumulating result }
      tenvpair = record
        sym : tsym;
        val : tceval;
      end;

      pframe = ^tframe;
      tframe = record
        shared    : pceshared;
        env       : array of tenvpair;
        envcount  : longint;
        depth     : longint;
        hasresult : boolean;
        resultval : tceval;
        resultdef : tdef;
      end;

    procedure fail(f : pframe; const why : ansistring);
      begin
        if not f^.shared^.failed then
          begin
            f^.shared^.failed:=true;
            f^.shared^.reason:=why;
          end;
      end;

    { build a tconstexprint from a raw bit pattern with an explicit signedness }
    function make_cei(raw : qword; signed : boolean) : tconstexprint;
      begin
        result.overflow:=false;
        result.signed:=signed;
        if signed then
          result.svalue:=int64(raw)
        else
          result.uvalue:=raw;
      end;

    { truncate V to the exact width/signedness of DEF, i.e. reproduce the
      two's-complement wraparound of a value stored in a DEF-typed location }
    function trunc_to(const v : tconstexprint; def : tdef) : tconstexprint;
      var
        bits : longint;
        raw,mask : qword;
        sgn : boolean;
      begin
        sgn:=is_signed(def);
        bits:=def.size*8;
        raw:=v.uvalue; { the raw union bit pattern, sign-agnostic }
        if bits>=64 then
          result:=make_cei(raw,sgn)
        else
          begin
            mask:=(qword(1) shl bits)-1;
            raw:=raw and mask;
            if sgn and ((raw and (qword(1) shl (bits-1)))<>0) then
              raw:=raw or (not mask);
            result:=make_cei(raw,sgn);
          end;
      end;

    { ---- tceval helpers (float folding) ------------------------------------ }

    { round D to the exact IEEE precision of DEF, reproducing the per-step
      rounding SSE codegen performs: a single-typed result is rounded to single
      (round-to-nearest), a double-typed result is already at target precision. }
    function round_flt(d : double; def : tdef) : double;
      begin
        if is_single(def) then
          result:=double(single(d))
        else
          result:=d;
      end;

    function mk_ord(const v : tconstexprint) : tceval;
      begin
        result.kind:=cev_ord;
        result.ord:=v;
        result.flt:=0.0;
      end;

    function mk_flt(d : double) : tceval;
      begin
        result.kind:=cev_flt;
        result.ord:=make_cei(0,false);
        result.flt:=d;
      end;

    { convert an already-evaluated value to what a store into DEF-typed storage
      would hold: ordinal -> two's-complement truncation; float -> IEEE rounding;
      an integer source feeding a float DEF is an int->float conversion, rounded
      directly at the target precision (so a large int64 -> single is single-
      rounded once, matching cvtsi2ss rather than double-rounding). Returns false
      (site refuses) for a float source feeding an ordinal DEF. }
    function coerce_to(f : pframe; const v : tceval; def : tdef; out r : tceval) : boolean;
      begin
        result:=true;
        if foldable_float(def) then
          begin
            if v.kind=cev_flt then
              r:=mk_flt(round_flt(v.flt,def))
            else
              begin
                { int -> float }
                if is_single(def) then
                  begin
                    if v.ord.signed then
                      r:=mk_flt(double(single(v.ord.svalue)))
                    else
                      r:=mk_flt(double(single(v.ord.uvalue)));
                  end
                else
                  begin
                    if v.ord.signed then
                      r:=mk_flt(double(v.ord.svalue))
                    else
                      r:=mk_flt(double(v.ord.uvalue));
                  end;
              end;
          end
        else if is_ordinal(def) then
          begin
            if v.kind=cev_ord then
              r:=mk_ord(trunc_to(v.ord,def))
            else
              begin
                fail(f,'float-to-ordinal conversion'); result:=false;
              end;
          end
        else
          begin
            fail(f,'unsupported destination type'); result:=false;
          end;
      end;

    function env_lookup(f : pframe; sym : tsym; out v : tceval) : boolean;
      var
        i : longint;
      begin
        result:=false;
        for i:=0 to f^.envcount-1 do
          if f^.env[i].sym=sym then
            begin
              v:=f^.env[i].val;
              exit(true);
            end;
      end;

    procedure env_store(f : pframe; sym : tsym; const v : tceval);
      var
        i : longint;
      begin
        for i:=0 to f^.envcount-1 do
          if f^.env[i].sym=sym then
            begin
              f^.env[i].val:=v;
              exit;
            end;
        if f^.envcount>=length(f^.env) then
          setlength(f^.env,(f^.envcount+1)*2);
        f^.env[f^.envcount].sym:=sym;
        f^.env[f^.envcount].val:=v;
        inc(f^.envcount);
      end;

    function is_funcret_sym(sym : tsym) : boolean;
      begin
        result:=(sym is tabstractvarsym) and
                (vo_is_funcret in tabstractvarsym(sym).varoptions);
      end;

    function eval_expr(f : pframe; n : tnode; out v : tceval) : boolean; forward;
    function exec_stmt(f : pframe; n : tnode) : tflow; forward;
    function eval_const_call(f : pframe; call : tcallnode; out v : tceval) : boolean; forward;

    { evaluate an ordinal- or float-valued expression; false (and f.failed set)
      on anything the evaluator does not model or cannot fold soundly }
    function eval_expr(f : pframe; n : tnode; out v : tceval) : boolean;
      var
        lv,rv : tceval;
        ov : tconstexprint;
        sym : tsym;
        b : boolean;
        fres : double;
      begin
        result:=false;
        if f^.shared^.failed then
          exit;
        if not assigned(n) then
          begin
            fail(f,'empty expression'); exit;
          end;
        dec(f^.shared^.steps);
        if f^.shared^.steps<=0 then
          begin
            fail(f,'step budget exceeded'); exit;
          end;
        { the evaluator models ordinals and single/double floats; anything else
          (extended/comp/currency, set, string, pointer, ...) makes the site
          refuse }
        if assigned(n.resultdef) and
           not(is_ordinal(n.resultdef) or foldable_float(n.resultdef)) then
          begin
            fail(f,'unsupported value type'); exit;
          end;
        case n.nodetype of
          ordconstn:
            begin
              v:=mk_ord(trunc_to(tordconstnode(n).value,n.resultdef));
              result:=true;
            end;
          realconstn:
            begin
              if not foldable_float(n.resultdef) then
                begin fail(f,'unsupported float constant'); exit; end;
              { value_real is bestreal (widest); round once to the literal's own
                precision, matching the single/double constant codegen emits }
              v:=mk_flt(round_flt(trealconstnode(n).value_real,n.resultdef));
              result:=true;
            end;
          loadn:
            begin
              sym:=tloadnode(n).symtableentry;
              if is_funcret_sym(sym) then
                begin
                  if not f^.hasresult then
                    begin
                      fail(f,'reads uninitialised result'); exit;
                    end;
                  v:=f^.resultval;
                  result:=true;
                end
              else if (sym is tlocalvarsym) or (sym is tparavarsym) then
                begin
                  if not env_lookup(f,sym,v) then
                    begin
                      fail(f,'reads uninitialised local'); exit;
                    end;
                  result:=true;
                end
              else
                fail(f,'reads a non-local symbol');
            end;
          typeconvn:
            begin
              if not eval_expr(f,ttypeconvnode(n).left,lv) then
                exit;
              { ordinal wraparound, int->float rounding, single<->double
                rounding; a float->ordinal cast makes the site refuse }
              result:=coerce_to(f,lv,n.resultdef,v);
            end;
          addn,subn,muln:
            begin
              if not eval_expr(f,tbinarynode(n).left,lv) then exit;
              if not eval_expr(f,tbinarynode(n).right,rv) then exit;
              if foldable_float(n.resultdef) then
                begin
                  { round every intermediate to the node's own precision so a
                    single op rounds to single per step (add/sub/mul of two
                    single values are exact in double, so double-then-round is
                    the correctly-rounded single result -- bit-identical to the
                    addss/subss/mulss codegen would emit) }
                  if (lv.kind<>cev_flt) or (rv.kind<>cev_flt) then
                    begin fail(f,'non-float arithmetic operand'); exit; end;
                  case n.nodetype of
                    addn: fres:=lv.flt+rv.flt;
                    subn: fres:=lv.flt-rv.flt;
                    muln: fres:=lv.flt*rv.flt;
                    else
                      fres:=0.0; { unreachable }
                  end;
                  v:=mk_flt(round_flt(fres,n.resultdef));
                end
              else
                begin
                  if ([cs_check_overflow,cs_check_range]*n.localswitches)<>[] then
                    begin fail(f,'checked arithmetic'); exit; end;
                  if (lv.kind<>cev_ord) or (rv.kind<>cev_ord) then
                    begin fail(f,'non-ordinal arithmetic operand'); exit; end;
                  case n.nodetype of
                    addn: ov:=lv.ord+rv.ord;
                    subn: ov:=lv.ord-rv.ord;
                    muln: ov:=lv.ord*rv.ord;
                    else
                      ov:=make_cei(0,false); { unreachable }
                  end;
                  v:=mk_ord(trunc_to(ov,n.resultdef));
                end;
              result:=true;
            end;
          unaryminusn:
            begin
              if not eval_expr(f,tunarynode(n).left,lv) then exit;
              if foldable_float(n.resultdef) then
                begin
                  if lv.kind<>cev_flt then
                    begin fail(f,'non-float negation'); exit; end;
                  v:=mk_flt(round_flt(-lv.flt,n.resultdef));
                end
              else
                begin
                  if ([cs_check_overflow,cs_check_range]*n.localswitches)<>[] then
                    begin fail(f,'checked arithmetic'); exit; end;
                  if lv.kind<>cev_ord then
                    begin fail(f,'non-ordinal negation'); exit; end;
                  v:=mk_ord(trunc_to(-lv.ord,n.resultdef));
                end;
              result:=true;
            end;
          equaln,unequaln,ltn,lten,gtn,gten:
            begin
              if not eval_expr(f,tbinarynode(n).left,lv) then exit;
              if not eval_expr(f,tbinarynode(n).right,rv) then exit;
              if (lv.kind=cev_flt) or (rv.kind=cev_flt) then
                begin
                  if (lv.kind<>cev_flt) or (rv.kind<>cev_flt) then
                    begin fail(f,'mixed float comparison'); exit; end;
                  case n.nodetype of
                    equaln:   b:=lv.flt=rv.flt;
                    unequaln: b:=lv.flt<>rv.flt;
                    ltn:      b:=lv.flt<rv.flt;
                    lten:     b:=lv.flt<=rv.flt;
                    gtn:      b:=lv.flt>rv.flt;
                    gten:     b:=lv.flt>=rv.flt;
                    else
                      begin b:=false; { unreachable } end;
                  end;
                end
              else
                case n.nodetype of
                  equaln:   b:=lv.ord=rv.ord;
                  unequaln: b:=lv.ord<>rv.ord;
                  ltn:      b:=lv.ord<rv.ord;
                  lten:     b:=lv.ord<=rv.ord;
                  gtn:      b:=lv.ord>rv.ord;
                  gten:     b:=lv.ord>=rv.ord;
                  else
                    begin b:=false; { unreachable } end;
                end;
              v:=mk_ord(make_cei(ord(b),false));
              result:=true;
            end;
          andn,orn,xorn:
            begin
              if not eval_expr(f,tbinarynode(n).left,lv) then exit;
              if not eval_expr(f,tbinarynode(n).right,rv) then exit;
              if (lv.kind<>cev_ord) or (rv.kind<>cev_ord) then
                begin fail(f,'non-ordinal bitwise operand'); exit; end;
              if is_boolean(n.resultdef) then
                begin
                  { logical: operands are 0/1 }
                  case n.nodetype of
                    andn: b:=(lv.ord.uvalue<>0) and (rv.ord.uvalue<>0);
                    orn:  b:=(lv.ord.uvalue<>0) or (rv.ord.uvalue<>0);
                    xorn: b:=(lv.ord.uvalue<>0) xor (rv.ord.uvalue<>0);
                    else
                      begin b:=false; { unreachable } end;
                  end;
                  v:=mk_ord(make_cei(ord(b),false));
                end
              else
                begin
                  case n.nodetype of
                    andn: ov:=lv.ord and rv.ord;
                    orn:  ov:=lv.ord or rv.ord;
                    xorn: ov:=lv.ord xor rv.ord;
                    else
                      ov:=make_cei(0,false); { unreachable }
                  end;
                  v:=mk_ord(trunc_to(ov,n.resultdef));
                end;
              result:=true;
            end;
          notn:
            begin
              if not eval_expr(f,tunarynode(n).left,lv) then exit;
              if lv.kind<>cev_ord then
                begin fail(f,'non-ordinal not'); exit; end;
              if is_boolean(n.resultdef) then
                v:=mk_ord(make_cei(ord(lv.ord.uvalue=0),false))
              else
                v:=mk_ord(trunc_to(make_cei(not lv.ord.uvalue,false),n.resultdef));
              result:=true;
            end;
          inlinen:
            case tinlinenode(n).inlinenumber of
              in_ord_x,in_chr_byte:
                begin
                  if not eval_expr(f,tinlinenode(n).left,lv) then exit;
                  if lv.kind<>cev_ord then
                    begin fail(f,'non-ordinal intrinsic operand'); exit; end;
                  v:=mk_ord(trunc_to(lv.ord,n.resultdef));
                  result:=true;
                end;
              in_abs_long:
                begin
                  if not eval_expr(f,tinlinenode(n).left,lv) then exit;
                  if lv.kind<>cev_ord then
                    begin fail(f,'non-ordinal abs operand'); exit; end;
                  ov:=lv.ord;
                  if ov.is_negative then
                    ov:=-ov;
                  v:=mk_ord(trunc_to(ov,n.resultdef));
                  result:=true;
                end;
              in_sqr_real:
                { the compiler auto-rewrites  x*x  to sqr(x); codegen emits a
                  single mulss/mulsd, so x*x rounded to the node precision is
                  bit-identical (exact in double for single operands, native
                  double mul for double) }
                begin
                  if not eval_expr(f,tinlinenode(n).left,lv) then exit;
                  if (lv.kind<>cev_flt) or not foldable_float(n.resultdef) then
                    begin fail(f,'non-float sqr'); exit; end;
                  v:=mk_flt(round_flt(lv.flt*lv.flt,n.resultdef));
                  result:=true;
                end;
              in_abs_real:
                { |x| just clears the sign bit -- exact, rounding is a no-op }
                begin
                  if not eval_expr(f,tinlinenode(n).left,lv) then exit;
                  if (lv.kind<>cev_flt) or not foldable_float(n.resultdef) then
                    begin fail(f,'non-float abs'); exit; end;
                  v:=mk_flt(round_flt(abs(lv.flt),n.resultdef));
                  result:=true;
                end;
              else
                fail(f,'unsupported intrinsic');
            end;
          calln:
            result:=eval_const_call(f,tcallnode(n),v);
          else
            fail(f,'unsupported expression node');
        end;
      end;

    { look up the block index a case selector value falls into (or -1) }
    function case_find_block(lbl : pcaselabel; const v : tconstexprint;
      sgn : boolean) : longint;
      var
        lo,hi : tconstexprint;
      begin
        result:=-1;
        while assigned(lbl) do
          begin
            if lbl^.label_type<>ltOrdinal then
              exit(-2); { non-ordinal (string) case: refuse }
            lo:=make_cei(lbl^._low.uvalue,sgn);
            hi:=make_cei(lbl^._high.uvalue,sgn);
            if v<lo then
              lbl:=lbl^.less
            else if v>hi then
              lbl:=lbl^.greater
            else
              exit(lbl^.blockid);
          end;
      end;

    { execute a statement; returns how control left it }
    function exec_stmt(f : pframe; n : tnode) : tflow;
      var
        cur : tnode;
        cv : tceval;
        fromv,tov,ctr,ordv : tconstexprint;
        sym : tsym;
        target : tnode;
        seldef : tdef;
        sgn,backward : boolean;
        blk : longint;
        casen_node : tcasenode;
      begin
        result:=fl_normal;
        if f^.shared^.failed then
          exit;
        if not assigned(n) then
          exit;
        dec(f^.shared^.steps);
        if f^.shared^.steps<=0 then
          begin
            fail(f,'step budget exceeded'); exit;
          end;
        case n.nodetype of
          nothingn:
            ;
          blockn:
            begin
              cur:=tblocknode(n).statements;
              while assigned(cur) and (result=fl_normal) and not f^.shared^.failed do
                begin
                  result:=exec_stmt(f,tstatementnode(cur).statement);
                  cur:=tstatementnode(cur).next;
                end;
            end;
          statementn:
            result:=exec_stmt(f,tstatementnode(n).statement);
          assignn:
            begin
              target:=tassignmentnode(n).left;
              { the funcret / local l-value may be wrapped in a (tc_equal)
                type conversion; peel it to reach the underlying load }
              while (target.nodetype=typeconvn) do
                target:=ttypeconvnode(target).left;
              if target.nodetype<>loadn then
                begin
                  fail(f,'assigns a non-local l-value'); exit;
                end;
              if not eval_expr(f,tassignmentnode(n).right,cv) then
                exit;
              if not coerce_to(f,cv,target.resultdef,cv) then
                exit;
              sym:=tloadnode(target).symtableentry;
              if is_funcret_sym(sym) then
                begin
                  f^.resultval:=cv;
                  f^.hasresult:=true;
                end
              else if (sym is tlocalvarsym) or (sym is tparavarsym) then
                env_store(f,sym,cv)
              else
                fail(f,'assigns a non-local symbol');
            end;
          ifn:
            begin
              if not eval_expr(f,tifnode(n).left,cv) then
                exit;
              if cv.ord.uvalue<>0 then
                result:=exec_stmt(f,tifnode(n).right)
              else if assigned(tifnode(n).t1) then
                result:=exec_stmt(f,tifnode(n).t1);
            end;
          whilerepeatn:
            begin
              while not f^.shared^.failed do
                begin
                  dec(f^.shared^.steps);
                  if f^.shared^.steps<=0 then
                    begin fail(f,'step budget exceeded'); exit; end;
                  if lnf_testatbegin in tloopnode(n).loopflags then
                    begin
                      if not eval_expr(f,tloopnode(n).left,cv) then exit;
                      if lnf_checknegate in tloopnode(n).loopflags then
                        cv:=mk_ord(make_cei(ord(cv.ord.uvalue=0),false));
                      if cv.ord.uvalue=0 then
                        break;
                    end;
                  result:=exec_stmt(f,tloopnode(n).right);
                  if result=fl_break then
                    begin result:=fl_normal; break; end;
                  if result=fl_exit then
                    exit;
                  result:=fl_normal; { fl_continue and fl_normal both re-test }
                  if not(lnf_testatbegin in tloopnode(n).loopflags) then
                    begin
                      if not eval_expr(f,tloopnode(n).left,cv) then exit;
                      if lnf_checknegate in tloopnode(n).loopflags then
                        cv:=mk_ord(make_cei(ord(cv.ord.uvalue=0),false));
                      if cv.ord.uvalue=0 then
                        break;
                    end;
                end;
            end;
          forn:
            begin
              target:=tfornode(n).left;
              if (target.nodetype<>loadn) then
                begin fail(f,'for-loop counter not a simple variable'); exit; end;
              sym:=tloadnode(target).symtableentry;
              if not((sym is tlocalvarsym) or (sym is tparavarsym)) then
                begin fail(f,'for-loop counter not a local'); exit; end;
              if not eval_expr(f,tfornode(n).right,cv) then exit;
              if cv.kind<>cev_ord then
                begin fail(f,'non-ordinal for-loop bound'); exit; end;
              fromv:=trunc_to(cv.ord,target.resultdef);
              if not eval_expr(f,tfornode(n).t1,cv) then exit;
              if cv.kind<>cev_ord then
                begin fail(f,'non-ordinal for-loop bound'); exit; end;
              tov:=trunc_to(cv.ord,target.resultdef);
              backward:=lnf_backward in tfornode(n).loopflags;
              ctr:=fromv;
              { empty-range check up front (Pascal evaluates bounds once) }
              if (not backward and (ctr>tov)) or (backward and (ctr<tov)) then
                { loop body never executes }
              else
                while not f^.shared^.failed do
                  begin
                    dec(f^.shared^.steps);
                    if f^.shared^.steps<=0 then
                      begin fail(f,'step budget exceeded'); exit; end;
                    env_store(f,sym,mk_ord(ctr));
                    result:=exec_stmt(f,tfornode(n).t2);
                    if result=fl_break then
                      begin result:=fl_normal; break; end;
                    if result=fl_exit then
                      exit;
                    result:=fl_normal;
                    { stop at the boundary to avoid overflow past high/low }
                    if ctr=tov then
                      break;
                    if backward then
                      ctr:=trunc_to(ctr-make_cei(1,true),target.resultdef)
                    else
                      ctr:=trunc_to(ctr+make_cei(1,true),target.resultdef);
                  end;
            end;
          casen:
            begin
              casen_node:=tcasenode(n);
              seldef:=casen_node.left.resultdef;
              if not eval_expr(f,casen_node.left,cv) then exit;
              if cv.kind<>cev_ord then
                begin fail(f,'non-ordinal case selector'); exit; end;
              sgn:=is_signed(seldef);
              ordv:=make_cei(cv.ord.uvalue,sgn);
              blk:=case_find_block(casen_node.labels,ordv,sgn);
              if blk=-2 then
                begin fail(f,'non-ordinal case'); exit; end;
              if blk>=0 then
                begin
                  if (blk<casen_node.blocks.count) and assigned(casen_node.blocks[blk]) then
                    result:=exec_stmt(f,pcaseblock(casen_node.blocks[blk])^.statement);
                end
              else if assigned(casen_node.elseblock) then
                result:=exec_stmt(f,casen_node.elseblock);
            end;
          exitn:
            begin
              if assigned(texitnode(n).resultexpr) then
                begin
                  if not eval_expr(f,texitnode(n).resultexpr,cv) then exit;
                  if not coerce_to(f,cv,f^.resultdef,f^.resultval) then exit;
                  f^.hasresult:=true;
                end;
              result:=fl_exit;
            end;
          breakn:
            result:=fl_break;
          continuen:
            result:=fl_continue;
          calln:
            { a bare procedure-call statement: evaluate for its (absence of)
              effect -- a const routine has no side effects, so discard }
            if not eval_const_call(f,tcallnode(n),cv) then
              exit;
          else
            fail(f,'unsupported statement node');
        end;
      end;

    { seed a fresh frame from a call's actual constant arguments and interpret
      the callee body; STEP/DEPTH state is shared with the enclosing frame }
    function eval_const_call(f : pframe; call : tcallnode; out v : tceval) : boolean;
      var
        callee : tprocdef;
        body : tnode;
        pn : tcallparanode;
        sub : tframe;
        av,seeded : tceval;
      begin
        result:=false;
        if assigned(call.methodpointer) then
          begin fail(f,'method-pointer call'); exit; end;
        if not assigned(call.procdefinition) or
           (call.procdefinition.typ<>procdef) then
          begin fail(f,'indirect call'); exit; end;
        callee:=tprocdef(call.procdefinition);
        if not proc_is_const(callee) then
          begin fail(f,'callee not proven const'); exit; end;
        if not foldable_scalar(callee.returndef) then
          begin fail(f,'callee result not a foldable scalar'); exit; end;
        if f^.depth+1>consteval_depth_cap then
          begin fail(f,'recursion cap exceeded'); exit; end;
        body:=get_callee_body(callee);
        if not assigned(body) then
          begin fail(f,'callee body unavailable'); exit; end;

        { build the callee frame, evaluating each actual in the CURRENT frame }
        fillchar(sub,sizeof(sub),0);
        sub.shared:=f^.shared;
        sub.depth:=f^.depth+1;
        sub.resultdef:=callee.returndef;
        sub.hasresult:=false;
        setlength(sub.env,4);
        sub.envcount:=0;

        pn:=tcallparanode(call.left);
        while assigned(pn) do
          begin
            if assigned(pn.parasym) and assigned(pn.left) and
               (pn.parasym is tparavarsym) and
               not(vo_is_hidden_para in tparavarsym(pn.parasym).varoptions) then
              begin
                if not foldable_scalar(tparavarsym(pn.parasym).vardef) then
                  begin fail(f,'non-foldable argument'); exit; end;
                if not eval_expr(f,pn.left,av) then
                  exit;
                if not coerce_to(f,av,tparavarsym(pn.parasym).vardef,seeded) then
                  exit;
                env_store(@sub,tsym(pn.parasym),seeded);
              end;
            pn:=tcallparanode(pn.right);
          end;

        if exec_stmt(@sub,body)=fl_exit then
          ; { exit just terminates the body }
        if f^.shared^.failed then
          exit;
        if not sub.hasresult then
          begin fail(f,'callee never assigned its result'); exit; end;
        result:=coerce_to(f,sub.resultval,callee.returndef,v);
      end;

    { ---- top-level call-site folding --------------------------------------- }

    { returns the computed literal for a foldable direct call, or nil (and sets
      REASON) if the site cannot be folded }
    function try_fold_call(call : tcallnode; out reason : ansistring) : tnode;
      var
        callee : tprocdef;
        body : tnode;
        pn : tcallparanode;
        shared : tceshared;
        top : tframe;
        av,seeded : tceval;
        argcount : longint;
      begin
        result:=nil;
        reason:='';
        if assigned(call.methodpointer) then
          begin reason:='method-pointer call'; exit; end;
        if not assigned(call.procdefinition) or
           (call.procdefinition.typ<>procdef) then
          begin reason:='indirect call'; exit; end;
        callee:=tprocdef(call.procdefinition);
        if not proc_is_const(callee) then
          begin reason:='not proven const'; exit; end;
        if not foldable_scalar(callee.returndef) then
          begin reason:='result not a foldable scalar'; exit; end;

        { every actual must be a compile-time constant of a foldable scalar type:
          an ordinal constant, or a single/double real constant }
        argcount:=0;
        pn:=tcallparanode(call.left);
        while assigned(pn) do
          begin
            if assigned(pn.parasym) and
               not(vo_is_hidden_para in tparavarsym(pn.parasym).varoptions) then
              begin
                inc(argcount);
                if not assigned(pn.left) or
                   not(pn.left.nodetype in [ordconstn,realconstn]) then
                  begin reason:='non-constant argument'; exit; end;
                if not foldable_scalar(pn.left.resultdef) then
                  begin reason:='non-foldable argument'; exit; end;
              end;
            pn:=tcallparanode(pn.right);
          end;

        body:=get_callee_body(callee);
        if not assigned(body) then
          begin reason:='body unavailable'; exit; end;

        shared.steps:=consteval_step_budget;
        shared.failed:=false;
        shared.reason:='';
        fillchar(top,sizeof(top),0);
        top.shared:=@shared;
        top.depth:=0;
        top.resultdef:=callee.returndef;
        top.hasresult:=false;
        setlength(top.env,4);
        top.envcount:=0;

        pn:=tcallparanode(call.left);
        while assigned(pn) do
          begin
            if assigned(pn.parasym) and assigned(pn.left) and
               (pn.parasym is tparavarsym) and
               not(vo_is_hidden_para in tparavarsym(pn.parasym).varoptions) then
              begin
                { evaluate the (constant) actual and coerce to the parameter type }
                if not eval_expr(@top,pn.left,av) then
                  begin reason:=shared.reason; exit; end;
                if not coerce_to(@top,av,tparavarsym(pn.parasym).vardef,seeded) then
                  begin reason:=shared.reason; exit; end;
                env_store(@top,tsym(pn.parasym),seeded);
              end;
            pn:=tcallparanode(pn.right);
          end;

        if exec_stmt(@top,body)=fl_exit then
          ;
        if shared.failed then
          begin reason:=shared.reason; exit; end;
        if not top.hasresult then
          begin reason:='result never assigned'; exit; end;

        { emit the computed literal: an ordinal const for an ordinal result, a
          real const (already rounded to the result precision) for a float one }
        if top.resultval.kind=cev_flt then
          result:=crealconstnode.create(top.resultval.flt,callee.returndef)
        else
          result:=cordconstnode.create(trunc_to(top.resultval.ord,callee.returndef),
            callee.returndef,false);
        typecheckpass(result);
      end;

    function scan_calls(var n : tnode; arg : pointer) : foreachnoderesult;
      var
        call : tcallnode;
        lit : tnode;
        reason : ansistring;
        calleename : string;
      begin
        result:=fen_true;
        if n.nodetype<>calln then
          exit;
        call:=tcallnode(n);
        if not assigned(call.procdefinition) or
           (call.procdefinition.typ<>procdef) then
          exit;
        calleename:=tprocdef(call.procdefinition).procsym.realname;
        lit:=try_fold_call(call,reason);
        if assigned(lit) then
          begin
            OptRemark(call.fileinfo,'consteval','call to '+calleename+
              ' folded to compile-time constant');
            n.free;
            n:=lit;
          end
        else if reason<>'' then
          { only remark a genuine near-miss (a call to a const routine we could
            not fold), not every ordinary call }
          if (assigned(call.procdefinition)) and
             proc_is_const(tprocdef(call.procdefinition)) then
            OptRemark(call.fileinfo,'consteval','call to '+calleename+
              ' not folded: '+reason);
      end;

    procedure consteval_process_calls(callerpd : tprocdef; var code : tnode);
      begin
        if not assigned(code) then
          exit;
        consteval_module_check;
        foreachnodestatic(pm_postprocess,code,@scan_calls,nil);
      end;

end.
