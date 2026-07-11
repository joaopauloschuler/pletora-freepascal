{
    Replaces calls by inline code

    Copyright (c) 1998-2026 by Florian Klaempfl and others

    This program is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program; if not, write to the Free Software
    Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.

 ****************************************************************************
}

unit optcall;

{$i fpcdefs.inc}

{ $define EXTDEBUG_INLINE}

  interface

    uses
      node;

    procedure do_optinline(var rootnode : tnode;out changed: boolean);

  implementation

    uses
      cclasses,
      verbose,globals,
      defutil,defcmp,
      symconst,symtype,symdef,symsym,
      parabase,paramgr,
      procinfo,
      nutils,
      fmodule,
      pass_1,
      aasmbase,aasmtai,aasmdata,
      nbas,ncal,nld;

    { this procedure removes the user code flag because it prevents optimizations }
    function removeusercodeflag(var n : tnode; arg : pointer) : foreachnoderesult;
      begin
        result:=fen_false;
        if nf_usercode_entry in n.flags then
          begin
            exclude(n.flags,nf_usercode_entry);
            result:=fen_norecurse_true;
          end;
      end;


    { FPC Unleashed: give each spliced copy of an inline asm block its own fresh
      AB_LOCAL asm labels. When a routine with an inner "asm ... jge .Lok ...
      .Lok: ..." block is inlined at two+ call sites, dogetcopy's concatlistcopy
      aliases the SAME tasmlabel across the copies, and tcgasmnode's alt-symbol
      relabel always uses alt number 1 -- so both copies would emit "name_1" and
      the assembler reports "Duplicate label". We rebind every AB_LOCAL label
      DEFINED in this copy to a freshly allocated label (unique module-wide),
      rewriting the definition AND every reference (branch operands, ait_const
      sym/endsym) consistently, so each site's jmp/label pair is self-contained.
      The alt-symbol pass then still runs (asmnf_inline_copy) but now derives its
      "_1" names from distinct bases, so no collision. }
    procedure unique_inline_asm_labels(p_asm : TAsmList);
      var
        hp   : tai;
        i    : longint;
        oldl : array of tasmlabel;
        newl : array of tasmlabel;

      function mapped(sym : tasmsymbol) : tasmlabel;
        var
          j : longint;
        begin
          result:=nil;
          if not(assigned(sym) and (sym.bind=AB_LOCAL) and (sym is tasmlabel)) then
            exit;
          for j:=0 to high(oldl) do
            if oldl[j]=sym then
              exit(newl[j]);
        end;

      procedure remapsym(var sym : tasmsymbol);
        var
          m : tasmlabel;
        begin
          m:=mapped(sym);
          if assigned(m) then
            sym:=m;
        end;

      begin
        oldl:=nil;
        newl:=nil;
        if not assigned(p_asm) then
          exit;
        { pass 1: allocate a fresh label for each AB_LOCAL label DEFINED here }
        hp:=tai(p_asm.first);
        while assigned(hp) do
          begin
            if (hp.typ=ait_label) and
               assigned(tai_label(hp).labsym) and
               (tai_label(hp).labsym.bind=AB_LOCAL) and
               (mapped(tai_label(hp).labsym)=nil) then
              begin
                setlength(oldl,length(oldl)+1);
                setlength(newl,length(newl)+1);
                oldl[high(oldl)]:=tai_label(hp).labsym;
                current_asmdata.getjumplabel(newl[high(newl)]);
              end;
            hp:=tai(hp.next);
          end;
        if length(oldl)=0 then
          exit;
        { pass 2: rewrite definitions and every reference of the mapped labels }
        hp:=tai(p_asm.first);
        while assigned(hp) do
          begin
            case hp.typ of
              ait_label :
                begin
                  if assigned(mapped(tai_label(hp).labsym)) then
                    tai_label(hp).labsym:=mapped(tai_label(hp).labsym);
                end;
              ait_const :
                begin
                  remapsym(tai_const(hp).sym);
                  remapsym(tai_const(hp).endsym);
                end;
              ait_instruction :
                for i:=0 to tai_cpu_abstract(hp).ops-1 do
                  if tai_cpu_abstract(hp).oper[i]^.typ=top_ref then
                    begin
                      remapsym(tai_cpu_abstract(hp).oper[i]^.ref^.symbol);
                      remapsym(tai_cpu_abstract(hp).oper[i]^.ref^.relsymbol);
                    end;
              else
                ;
            end;
            hp:=tai(hp.next);
          end;
      end;


    { FPC Unleashed: flag asm blocks in an inlined body copy so tcgasmnode
      relabels their local asm labels for this call site, and give each copy its
      own fresh AB_LOCAL labels (see unique_inline_asm_labels). }
    function mark_inline_asm_copy(var n : tnode; arg : pointer) : foreachnoderesult;
      begin
        result:=fen_false;
        if (n.nodetype=asmn) and
           not(asmnf_get_asm_position in tasmnode(n).asmnodeflags) then
          begin
            include(tasmnode(n).asmnodeflags,asmnf_inline_copy);
            unique_inline_asm_labels(tasmnode(n).p_asm);
          end;
      end;


    function setinlinelevel(var n:tnode; arg:pointer):foreachnoderesult;
      begin
        if n.nodetype=calln then
          tcallnode(n).inlinelevel:=PtrUInt(arg);
        result:=fen_false;
      end;


    { reference symbols that are imported from another unit }
    function importglobalsyms(var n:tnode; arg:pointer):foreachnoderesult;
      var
        sym : tsym;
      begin
        result:=fen_false;
        if n.nodetype=loadn then
          begin
            sym:=tloadnode(n).symtableentry;
            if sym.typ=staticvarsym then
              begin
                if FindUnitSymtable(tloadnode(n).symtable).moduleid<>current_module.moduleid then
                  current_module.addimportedsym(sym);
              end
            else if (sym.typ=constsym) and (tconstsym(sym).consttyp in [constwresourcestring,constresourcestring]) then
              begin
                if tloadnode(n).symtableentry.owner.moduleid<>current_module.moduleid then
                  current_module.addimportedsym(sym);
              end;
          end
        else if (n.nodetype=calln) then
          begin
            if (assigned(tcallnode(n).procdefinition)) and
               (tcallnode(n).procdefinition.typ=procdef) and
               (findunitsymtable(tcallnode(n).procdefinition.owner).moduleid<>current_module.moduleid) then
              current_module.addimportedsym(tprocdef(tcallnode(n).procdefinition).procsym);
          end;
      end;


    function redoalinaparams(var n: tnode; arg: pointer): foreachnoderesult;
      begin
        result:=fen_false;
        if n.nodetype=calln then
          begin
            { re-init varargs paraloc that may have been invalidated by inlining }
            if assigned(tcallnode(n).varargsparas) then
              paramanager.create_varargs_paraloc_info(tcallnode(n).procdefinition,callerside,tcallnode(n).varargsparas);
            tcallnode(n).order_parameters;
          end;
      end;


    function doinline(var _n: tnode; arg: pointer): foreachnoderesult;
      var
        n,
        body : tnode;
        para : tcallparanode;
        inlineblock,
        inlinecleanupblock : tblocknode;
        callnode: tcallnode;
      begin
        result:=fen_false;
        { po_inline marks the ordinary inline routines; cnf_do_inline additionally
          covers -OoDEVIRT targets, which are virtual (never po_inline) but whose
          body was retained as inlining info and rebound here by
          tcallnode.devirt_prepare_inline }
        if not(_n.nodetype=calln) or
           not((po_inline in tcallnode(_n).procdefinition.procoptions) or
               (cnf_do_inline in tcallnode(_n).callnodeflags)) then
          exit;
        callnode:=tcallnode(_n);

        if not(callnode.doinlining) then
          begin
            if not(po_compilerproc in callnode.procdefinition.procoptions) then
              begin
                { FPC Unleashed: append the refusal reason when it is known
                  (routine defined in the current unit); see tprocdef.inlinenoreason }
                if tprocdef(callnode.procdefinition).inlinenoreason<>'' then
                  Message2(cg_n_no_inline,
                    tprocdef(callnode.procdefinition).customprocname([pno_proctypeoption, pno_paranames,pno_ownername, pno_noclassmarker, pno_prettynames]),
                    ' ('+tprocdef(callnode.procdefinition).inlinenoreason+')')
                else
                  Message2(cg_n_no_inline,
                    tprocdef(callnode.procdefinition).customprocname([pno_proctypeoption, pno_paranames,pno_ownername, pno_noclassmarker, pno_prettynames]),
                    '');
              end;
            exit;
          end;

        if not(assigned(tprocdef(callnode.procdefinition).inlininginfo) and
          assigned(tprocdef(callnode.procdefinition).inlininginfo^.code)) then
          internalerror(200412021);

        callnode.inlinelocals:=TFPObjectList.create(true);

        { inherit flags }
        current_procinfo.flags:=current_procinfo.flags+
          ((callnode.procdefinition as tprocdef).inlininginfo^.flags*inherited_inlining_flags);

        { Create new code block for inlining }
        inlineblock:=internalstatements(callnode.inlineinitstatement);
        { make sure that valid_for_assign() returns false for this block
          (otherwise assigning values to the block will result in assigning
           values to the inlined function's result) }
        include(inlineblock.flags,nf_no_lvalue);
        inlinecleanupblock:=internalstatements(callnode.inlinecleanupstatement);

        if assigned(callnode.callinitblock) then
          addstatement(callnode.inlineinitstatement,callnode.callinitblock.getcopy);

        { replace complex parameters with temps }
        callnode.createinlineparas;

        { create a copy of the body and replace parameter loads with the parameter values }
        body:=tprocdef(callnode.procdefinition).inlininginfo^.code.getcopy;
        { FPC Unleashed: mark any asm blocks in the spliced copy so tcgasmnode
          uniques their local labels at this call site (the enclosing routine is
          not necessarily po_inline). checknodeinlining has already guaranteed
          the blocks reference no local/parameter operands. }
        foreachnodestatic(pm_postprocess,body,@mark_inline_asm_copy,nil);
        foreachnodestatic(pm_postprocess,body,@ removeusercodeflag,nil);
        foreachnodestatic(pm_postprocess,body,@importglobalsyms,nil);
        foreachnodestatic(pm_postprocess,body,@setinlinelevel,pointer(callnode.inlinelevel+1));
        foreachnode(pm_preprocess,body,@callnode.replaceparaload,@callnode.fileinfo);

        { Concat the body and finalization parts }
        addstatement(callnode.inlineinitstatement,body);
        addstatement(callnode.inlineinitstatement,inlinecleanupblock);
        inlinecleanupblock:=nil;

        if assigned(callnode.callcleanupblock) then
          addstatement(callnode.inlineinitstatement,callnode.callcleanupblock.getcopy);

        { the last statement of the new inline block must return the
          location and type of the function result.
          This is not needed when the result is not used, also the tempnode is then
          already destroyed  by a tempdelete in the callcleanupblock tree }
        if not is_void(callnode.resultdef) and
           (cnf_return_value_used in callnode.callnodeflags) then
          begin
            if assigned(callnode.funcretnode) then
              addstatement(callnode.inlineinitstatement,callnode.funcretnode.getcopy)
            else
              begin
                para:=tcallparanode(callnode.left);
                while assigned(para) do
                  begin
                    if (vo_is_hidden_para in para.parasym.varoptions) and
                       (vo_is_funcret in para.parasym.varoptions) then
                      begin
                        addstatement(callnode.inlineinitstatement,para.left.getcopy);
                        break;
                      end;
                    para:=tcallparanode(para.right);
                  end;
              end;
          end;

        typecheckpass(tnode(inlineblock));
        doinlinesimplify(tnode(inlineblock));
        firstpass(tnode(inlineblock));
        _n:=inlineblock;

        { if the function result is used then verify that the blocknode
          returns the same result type as the original callnode }
        if (cnf_return_value_used in callnode.callnodeflags) and
           not(equal_defs(_n.resultdef,callnode.resultdef)) then
          internalerror(200709171);

        { free the temps for the locals }
        callnode.inlinelocals.free;
        callnode.inlinelocals:=nil;
        callnode.inlineinitstatement:=nil;
        callnode.inlinecleanupstatement:=nil;

        n:=callnode.optimize_funcret_assignment(inlineblock);
        if assigned(n) then
          begin
            inlineblock.free;
            inlineblock:=nil;
            _n:=n;
          end;

        PBoolean(arg)^:=true;

{$ifdef EXTDEBUG_INLINE}
        writeln;
        writeln('**************************************************************************************************************');
        writeln('************************** Inlined ',tprocdef(callnode.procdefinition).mangledname,'**************************');
        writeln('**************************************************************************************************************');
{$endif EXTDEBUG_INLINE}
      end;


    procedure do_optinline(var rootnode: tnode;out changed: boolean);
      begin
        changed:=false;
{$ifdef EXTDEBUG_INLINE}
        writeln('************************ Tree before inlining ******************************');
        printnode(rootnode);
        writeln('****************************************************************************');
{$endif EXTDEBUG_INLINE}
        foreachnodestatic(pm_postprocess, rootnode, @doinline, @changed);
        if changed then
          begin
            doinlinesimplify(rootnode);
            { after inlining, call nodes in the tree may have parameters
              whose subtrees now contain additional calls (e.g. fpc_shortstr_sint
              from an inlined str() call). The parent call nodes need their
              parameter analysis redone to recalculate parameter ordering and
              stack tainting info, otherwise parameters may be evaluated in the
              wrong order corrupting already pushed stack parameters }
            foreachnodestatic(pm_postprocess,rootnode,@redoalinaparams,nil);
{$ifdef EXTDEBUG_INLINE}
            writeln('************************ Tree after inlining ******************************');
            printnode(rootnode);
            writeln('****************************************************************************');
{$endif EXTDEBUG_INLINE}
          end;
      end;

end.

