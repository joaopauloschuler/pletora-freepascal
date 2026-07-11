{
    DFA

    Copyright (c) 2007 by Florian Klaempfl

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

{ $define DEBUG_DFA}
{ $define EXTDEBUG_DFA}

{ this unit implements routines to perform dfa }
unit optdfa;

{$i fpcdefs.inc}

  interface

    uses
      cclasses,
      node,optutils;

    type
      TDFABuilder = class
      protected
        procedure CreateLifeInfo(node : tnode;map : TIndexedNodeSet);
      public
        resultnode : tnode;
        nodemap : TIndexedNodeSet;
        { reset all dfa info, this is required before creating dfa info
          if the tree has been changed without updating dfa }
        procedure resetdfainfo(node : tnode);

        procedure createdfainfo(node : tnode);
        procedure redodfainfo(node : tnode);
        destructor destroy;override;
      end;

    procedure CheckAndWarn(code : tnode;nodetosearch : tnode);

    { Collect into syms every local/static array variable whose only accesses are
      matched loop-fill / loop-read shapes (see the block comment at the
      implementation of LoopFillCovered).  Must be called on the still-structured
      for-node tree, before ConvertForLoops lowers the loops.  The DFA
      "uninitialized" warning is a false positive for these variables. }
    procedure CollectLoopFillCoveredSyms(code : tnode;syms : tfplist);

  implementation

    uses
      globtype,cdynset,
      systems,
      constexp,
      verbose,
      symconst,symtype,symdef,symsym,
      defutil,
      procinfo,
      nutils,htypechk,
      nbas,nflw,ncal,nset,nld,nadd,nmem,ncnv,ncon,
      optbase;


    (*
    function initnodes(var n:tnode; arg: pointer) : foreachnoderesult;
      begin
        { node worth to add? }
        if (node_complexity(n)>1) and (tstoreddef(n.resultdef).is_intregable or tstoreddef(n.resultdef).is_fpuregable) then
          begin
            plists(arg)^.nodelist.Add(n);
            plists(arg)^.locationlist.Add(@n);
            result:=fen_false;
          end
        else
          result:=fen_norecurse_false;
      end;
    *)

    {
      x:=f;         read: [f]

      while x do    read: []

        a:=b;       read: [a,b,d]  def: [a]       life:  read*def=[a]
          c:=d;     read: [a,d]    def: [a,c]     life:  read*def=[a]
            e:=a;   read: [a]      def: [a,c,e]   life:  read*def=[a]


      function f(b,d,x : type) : type;

        begin
          while x do        alive: b,d,x
            begin
              a:=b;         alive: b,d,x
              c:=d;         alive: a,d,x
              e:=a+c;       alive: a,c,x
              dec(x);       alive: c,e,x
            end;
          result:=c+e;      alive: c,e
        end;                alive: result

    }

    type
      tdfainfo = record
        use : PDFASet;
        def : PDFASet;
        map : TIndexedNodeSet
      end;
      pdfainfo = ^tdfainfo;

    function AddDefUse(var n: tnode; arg: pointer): foreachnoderesult;
      begin
        case n.nodetype of
          tempcreaten:
            begin
              if assigned(ttempcreatenode(n).tempinfo^.tempinitcode) then
                begin
                  pdfainfo(arg)^.map.Add(n);
                  DynSetInclude(pdfainfo(arg)^.def^,n.optinfo^.index);
                end;
            end;
          temprefn,
          loadn:
            begin
              pdfainfo(arg)^.map.Add(n);
              if nf_modify in n.flags then
                begin
                  DynSetInclude(pdfainfo(arg)^.use^,n.optinfo^.index);
                  DynSetInclude(pdfainfo(arg)^.def^,n.optinfo^.index)
                end
              else if nf_write in n.flags then
                DynSetInclude(pdfainfo(arg)^.def^,n.optinfo^.index)
              else
                DynSetInclude(pdfainfo(arg)^.use^,n.optinfo^.index);
            end;
          else
            ;
        end;
        result:=fen_false;
      end;


    function ResetProcessing(var n: tnode; arg: pointer): foreachnoderesult;
      begin
        exclude(n.transientflags,tnf_processing);
        { dfa works only on normalized trees, so do not recurse into expressions, because
          ResetProcessing eats a significant amount of time of CheckAndWarn

          the following set contains (hopefully) most of the expression nodes }
        if n.nodetype in [calln,inlinen,assignn,callparan,andn,addn,orn,subn,muln,divn,slashn,notn,equaln,unequaln,gtn,ltn,lten,gten,loadn,
          typeconvn,vecn,subscriptn,addrn,derefn] then
          result:=fen_norecurse_false
        else
          result:=fen_false;
      end;


    function ResetDFA(var n: tnode; arg: pointer): foreachnoderesult;
      begin
        if assigned(n.optinfo) then
          begin
            with n.optinfo^ do
              begin
                life:=nil;
                def:=nil;
                use:=nil;
                defsum:=nil;
              end;
          end;
        result:=fen_false;
      end;


    procedure TDFABuilder.CreateLifeInfo(node : tnode;map : TIndexedNodeSet);

      var
        changed : boolean;

      procedure CreateInfo(node : tnode);

        { update life entry of a node with l, set changed if this changes
          life info for the node
        }
        procedure updatelifeinfo(n : tnode;const l : TDFASet);
          begin
            if not DynSetNotEqual(l,n.optinfo^.life) then
              exit;
{$ifdef DEBUG_DFA}
            if not(changed) then
              begin
                writeln('Another DFA pass caused by: ',nodetype2str[n.nodetype],'(',n.fileinfo.line,',',n.fileinfo.column,')');
                write('  Life info set was:     ');PrintDynSet(Output,n.optinfo^.life);writeln;
                write('  Life info set will be: ');PrintDynSet(Output,l);writeln;
              end;
{$endif DEBUG_DFA}

            changed:=true;
            n.optinfo^.life:=l;
          end;

        procedure calclife(n : tnode);
          var
            l : TDFASet;
          begin
            if assigned(n.successor) then
              begin
                { ensure we can access optinfo }
                DynSetDiff(l,n.successor.optinfo^.life,n.optinfo^.def);
                DynSetIncludeSet(l,n.optinfo^.use);
                DynSetIncludeSet(l,n.optinfo^.life);
              end
            else
              begin
                l:=n.optinfo^.use;
                DynSetIncludeSet(l,n.optinfo^.life);
              end;
            updatelifeinfo(n,l);
          end;

        var
          dfainfo : tdfainfo;
          l : TDFASet;
          save: TDFASet;
          lv, hv: TConstExprInt;
          i : longint;
          counteruse_after_loop : boolean;
        begin
          if node=nil then
            exit;

          { ensure we've already optinfo set }
          node.allocoptinfo;

          if tnf_processing in node.transientflags then
            exit;
          include(node.transientflags,tnf_processing);

          if assigned(node.successor) then
            CreateInfo(node.successor);

{$ifdef EXTDEBUG_DFA}
          writeln('Handling: ',nodetype2str[node.nodetype],'(',node.fileinfo.line,',',node.fileinfo.column,')');
{$endif EXTDEBUG_DFA}
          { life:=succesorlive-definition+use }

          case node.nodetype of
            whilerepeatn:
              begin
                { analyze the loop condition }
                if not(assigned(node.optinfo^.def)) and
                   not(assigned(node.optinfo^.use)) then
                  begin
                    dfainfo.use:=@node.optinfo^.use;
                    dfainfo.def:=@node.optinfo^.def;
                    dfainfo.map:=map;
                    foreachnodestatic(pm_postprocess,twhilerepeatnode(node).left,@AddDefUse,@dfainfo);
                  end;

                { NB: this node should typically have empty def set }
                if assigned(node.successor) then
                  DynSetDiff(l,node.successor.optinfo^.life,node.optinfo^.def)
                else if assigned(resultnode) then
                  DynSetDiff(l,resultnode.optinfo^.life,node.optinfo^.def)
                else
                  l:=nil;

                { for repeat..until, node use set in included at the end of loop }
                if not (lnf_testatbegin in twhilerepeatnode(node).loopflags) then
                  DynSetIncludeSet(l,node.optinfo^.use);

                DynSetIncludeSet(l,node.optinfo^.life);

                save:=node.optinfo^.life;
                { to process body correctly, we need life info in place (because
                  whilerepeatnode is successor of its body). }
                node.optinfo^.life:=l;

                { now process the body }
                CreateInfo(twhilerepeatnode(node).right);

                { restore, to prevent infinite recursion via changed flag }
                node.optinfo^.life:=save;

                { for while loops, node use set is included at the beginning of loop }
                l:=twhilerepeatnode(node).right.optinfo^.life;
                if lnf_testatbegin in twhilerepeatnode(node).loopflags then
                  begin
                    DynSetIncludeSet(l,node.optinfo^.use);
                    { ... loop body could be skipped, so include life info of the successor node }
                    if assigned(node.successor) then
                      DynSetIncludeSet(l,node.successor.optinfo^.life);
                  end;

                UpdateLifeInfo(node,l);

                { ... and a second iteration for fast convergence }
                CreateInfo(twhilerepeatnode(node).right);
              end;

            forn:
              begin
                {
                  left: loopvar
                  right: from
                  t1: to
                  t2: body
                }
                node.allocoptinfo;
                tfornode(node).loopiteration.allocoptinfo;
                if not(assigned(node.optinfo^.def)) and
                   not(assigned(node.optinfo^.use)) then
                  begin
                    dfainfo.use:=@node.optinfo^.use;
                    dfainfo.def:=@node.optinfo^.def;
                    dfainfo.map:=map;
                    foreachnodestatic(pm_postprocess,tfornode(node).left,@AddDefUse,@dfainfo);
                    foreachnodestatic(pm_postprocess,tfornode(node).right,@AddDefUse,@dfainfo);
                    foreachnodestatic(pm_postprocess,tfornode(node).t1,@AddDefUse,@dfainfo);
                  end;

                { create life for the body }
                CreateInfo(tfornode(node).t2);

                { is the counter living after the loop?

                  if left is a record element, it might not be tracked by dfa, so
                  optinfo might not be assigned
                }
                counteruse_after_loop:=assigned(tfornode(node).left.optinfo) and assigned(node.successor) and
                  DynSetIn(node.successor.optinfo^.life,tfornode(node).left.optinfo^.index);

                if counteruse_after_loop then
                  begin
                    { if yes, then we should warn }
                    { !!!!!! }
                  end
                else
                  Include(tfornode(node).loopflags,lnf_dont_mind_loopvar_on_exit);

                { first update the dummy node }

                { get the life of the loop block }
                l:=copy(tfornode(node).t2.optinfo^.life);

                { take care of the successor }
                if assigned(node.successor) then
                  DynSetIncludeSet(l,node.successor.optinfo^.life);

                { the counter variable is living as well inside the for loop

                  if left is a record element, it might not be tracked by dfa, so
                  optinfo might not be assigned
                }
                if assigned(tfornode(node).left.optinfo) then
                  DynSetInclude(l,tfornode(node).left.optinfo^.index);

                { force block node life info }
                UpdateLifeInfo(tfornode(node).loopiteration,l);

                { now update the for node itself }

                { get the life of the loop block }
                l:=copy(tfornode(node).t2.optinfo^.life);

                { take care of the successor as it's possible that we don't have one execution of the body }
                if (not(tfornode(node).right.nodetype=ordconstn) or not(tfornode(node).t1.nodetype=ordconstn)) and
                  assigned(node.successor) then
                  DynSetIncludeSet(l,node.successor.optinfo^.life);

                {
                  the counter variable is not living at the entry of the for node

                  if left is a record element, it might not be tracked by dfa, so
                    optinfo might not be assigned
                }
                if assigned(tfornode(node).left.optinfo) then
                  DynSetExclude(l,tfornode(node).left.optinfo^.index);

                { ... but it could be that left/right use it, so do this after
                  removing the def of the counter variable }
                DynSetIncludeSet(l,node.optinfo^.use);

                UpdateLifeInfo(node,l);

                { ... and a second iteration for fast convergence }
                CreateInfo(tfornode(node).t2);
              end;

            temprefn,
            loadn,
            typeconvn,
            derefn,
            assignn:
              begin
                if not(assigned(node.optinfo^.def)) and
                  not(assigned(node.optinfo^.use)) then
                  begin
                    dfainfo.use:=@node.optinfo^.use;
                    dfainfo.def:=@node.optinfo^.def;
                    dfainfo.map:=map;
                    foreachnodestatic(pm_postprocess,node,@AddDefUse,@dfainfo);
                  end;
                calclife(node);
              end;

            statementn:
              begin
                { nested statement }
                CreateInfo(tstatementnode(node).statement);
                { propagate info }
                node.optinfo^.life:=tstatementnode(node).successor.optinfo^.life;
              end;

            blockn:
              begin
                CreateInfo(tblocknode(node).statements);
                { ensure that we don't remove life info }
                l:=node.optinfo^.life;
                if assigned(node.successor) then
                  DynSetIncludeSet(l,node.successor.optinfo^.life);
                UpdateLifeInfo(node,l);
              end;

            ifn:
              begin
                { get information from cond. expression }
                if not(assigned(node.optinfo^.def)) and
                   not(assigned(node.optinfo^.use)) then
                  begin
                    dfainfo.use:=@node.optinfo^.use;
                    dfainfo.def:=@node.optinfo^.def;
                    dfainfo.map:=map;
                    foreachnodestatic(pm_postprocess,tifnode(node).left,@AddDefUse,@dfainfo);
                  end;

                { create life info for then and else node }
                CreateInfo(tifnode(node).right);
                CreateInfo(tifnode(node).t1);

                { ensure that we don't remove life info }
                l:=node.optinfo^.life;

                { get life info from then branch }
                if assigned(tifnode(node).right) then
                  DynSetIncludeSet(l,tifnode(node).right.optinfo^.life)
                else if assigned(node.successor) then
                  DynSetIncludeSet(l,node.successor.optinfo^.life);

                { get life info from else branch }
                if assigned(tifnode(node).t1) then
                  DynSetIncludeSet(l,tifnode(node).t1.optinfo^.life)
                else if assigned(node.successor) then
                  DynSetIncludeSet(l,node.successor.optinfo^.life);

                { remove def info from the cond. expression }
                DynSetExcludeSet(l,tifnode(node).optinfo^.def);

                { add use info from the cond. expression }
                DynSetIncludeSet(l,tifnode(node).optinfo^.use);

                { finally, update the life info of the node }
                UpdateLifeInfo(node,l);
              end;

            casen:
              begin
                { get information from "case" expression }
                if not(assigned(node.optinfo^.def)) and
                   not(assigned(node.optinfo^.use)) then
                  begin
                    dfainfo.use:=@node.optinfo^.use;
                    dfainfo.def:=@node.optinfo^.def;
                    dfainfo.map:=map;
                    foreachnodestatic(pm_postprocess,tcasenode(node).left,@AddDefUse,@dfainfo);
                  end;

                { create life info for block and else nodes }
                for i:=0 to tcasenode(node).blocks.count-1 do
                  CreateInfo(pcaseblock(tcasenode(node).blocks[i])^.statement);

                CreateInfo(tcasenode(node).elseblock);

                { ensure that we don't remove life info }
                l:=node.optinfo^.life;

                { get life info from case branches }
                for i:=0 to tcasenode(node).blocks.count-1 do
                  DynSetIncludeSet(l,pcaseblock(tcasenode(node).blocks[i])^.statement.optinfo^.life);

                { get life info from else branch or the successor }
                if assigned(tcasenode(node).elseblock) then
                  DynSetIncludeSet(l,tcasenode(node).elseblock.optinfo^.life)
                else if assigned(node.successor) then
                  begin
                    if is_ordinal(tcasenode(node).left.resultdef) then
                      begin
                        getrange(tcasenode(node).left.resultdef,lv,hv);
                        if tcasenode(node).labelcoverage<(hv-lv) then
                          DynSetIncludeSet(l,node.successor.optinfo^.life);
                      end
                    else
                      DynSetIncludeSet(l,node.successor.optinfo^.life);
                  end;

                { add use info from the "case" expression }
                DynSetIncludeSet(l,tcasenode(node).optinfo^.use);

                { finally, update the life info of the node }
                UpdateLifeInfo(node,l);
              end;

            exitn:
              begin
                { in case of inlining, an exit node can have a successor, in this case, we do not have to
                  use the faked resultnode }
                if assigned(node.successor) then
                  begin
                    l:=node.optinfo^.life;
                    DynSetIncludeSet(l,node.successor.optinfo^.life);
                    UpdateLifeInfo(node,l);
                  end
                else if assigned(resultnode) and (resultnode.nodetype<>nothingn) then
                  begin
                    if not(assigned(node.optinfo^.def)) and
                       not(assigned(node.optinfo^.use)) then
                      begin
                        if assigned(texitnode(node).left) then
                          begin
{                           this should never happen as
                            texitnode.pass_typecheck converts the left node into a separate node already

                             node.optinfo^.def:=resultnode.optinfo^.def;

                            dfainfo.use:=@node.optinfo^.use;
                            dfainfo.def:=@node.optinfo^.def;
                            dfainfo.map:=map;
                            foreachnodestatic(pm_postprocess,texitnode(node).left,@AddDefUse,@dfainfo);
                            calclife(node); }
                            Internalerror(2020122901);
                          end
                        else
                          begin
                            { get info from faked resultnode }
                            node.optinfo^.use:=resultnode.optinfo^.use;
                            node.optinfo^.life:=node.optinfo^.use;
                            changed:=true;
                          end;
                      end;
                  end;
              end;

{$ifdef JVM}
            { all other platforms except jvm translate raise nodes into call nodes during pass_1 }
            raisen,
{$endif JVM}
            tempcreaten,
            asn,
            inlinen,
            { autovectorizer body node: def/use are those of its vecn children
              (a[i] written, b[i]/c[i] read), collected by AddDefUse like a call }
            vectoropn,
            calln:
              begin
                if not(assigned(node.optinfo^.def)) and
                  not(assigned(node.optinfo^.use)) then
                  begin
                    dfainfo.use:=@node.optinfo^.use;
                    dfainfo.def:=@node.optinfo^.def;
                    dfainfo.map:=map;
                    foreachnodestatic(pm_postprocess,node,@AddDefUse,@dfainfo);
                  end;
                calclife(node);
              end;

            labeln,
            tempdeleten,
            nothingn,
            continuen,
            goton,
            breakn:
              begin
                calclife(node);
              end;
            else
              internalerror(2007050502);
          end;
        end;

      var
        runs : integer;
      begin
        runs:=0;
        repeat
          inc(runs);
          changed:=false;
          CreateInfo(node);
          foreachnodestatic(pm_postprocess,node,@ResetProcessing,nil);
          { the result node is not reached by foreachnodestatic }
          exclude(resultnode.transientflags,tnf_processing);
{$ifdef DEBUG_DFA}
          PrintIndexedNodeSet(output,map);
          PrintDFAInfo(output,node);
{$endif DEBUG_DFA}
        until not(changed);
{$ifdef DEBUG_DFA}
        writeln('DFA solver iterations: ',runs);
{$endif DEBUG_DFA}
      end;


    { reset all dfa info, this is required before creating dfa info
      if the tree has been changed without updating dfa }
    procedure TDFABuilder.resetdfainfo(node : tnode);
      begin
        nodemap.Free;
        nodemap:=nil;
        resultnode.Free;
        resultnode:=nil;
        foreachnodestatic(pm_postprocess,node,@ResetDFA,nil);
      end;


    procedure TDFABuilder.createdfainfo(node : tnode);
      var
        dfarec : tdfainfo;
      begin
        if not(assigned(nodemap)) then
          nodemap:=TIndexedNodeSet.Create;

        { create a fake node using the result which will be the last node }
        if not(is_void(current_procinfo.procdef.returndef)) then
          begin
            if current_procinfo.procdef.proctypeoption=potype_constructor then
              resultnode:=load_self_node
            else if (current_procinfo.procdef.proccalloption=pocall_safecall) and
              (tf_safecall_exceptions in target_info.flags) then
              resultnode:=load_safecallresult_node
            else
              resultnode:=load_result_node;
            resultnode.allocoptinfo;
            dfarec.use:=@resultnode.optinfo^.use;
            dfarec.def:=@resultnode.optinfo^.def;
            dfarec.map:=nodemap;
            AddDefUse(resultnode,@dfarec);
            resultnode.optinfo^.life:=resultnode.optinfo^.use;
          end
        else
          begin
            resultnode:=cnothingnode.create;
            resultnode.allocoptinfo;
          end;

        { add control flow information }
        SetNodeSucessors(node,resultnode);

        { now, collect life information }
        CreateLifeInfo(node,nodemap);
      end;


    procedure TDFABuilder.redodfainfo(node: tnode);
      begin
        resetdfainfo(node);
        createdfainfo(node);
        include(current_procinfo.flags,pi_dfaavailable);
      end;


    destructor TDFABuilder.Destroy;
      begin
        Resultnode.free;
        Resultnode := nil;
        nodemap.free;
        nodemap := nil;
        inherited destroy;
      end;

    type
      { helper structure to be able to pass more than one variable to the iterator function }
      TSearchNodeInfo = record
        nodetosearch : tnode;
        { this contains a list of all file locations where a warning was thrown already,
          the same location might appear multiple times because nodes might have been copied }
        warnedfilelocs : array of tfileposinfo;
      end;

      PSearchNodeInfo = ^TSearchNodeInfo;

    { searches for a given node n and warns if the node is found as being uninitialized. If a node is
      found, searching is stopped so each call issues only one warning/hint }
    function SearchNode(var n: tnode; arg: pointer): foreachnoderesult;

      function WarnedForLocation(f : tfileposinfo) : boolean;
        var
          i : longint;
        begin
          result:=true;
          for i:=0 to high(PSearchNodeInfo(arg)^.warnedfilelocs) do
            with PSearchNodeInfo(arg)^.warnedfilelocs[i] do
              begin
                if (f.column=column) and (f.fileindex=fileindex) and (f.line=line) and (f.moduleindex=moduleindex) then
                  exit;
              end;
          result:=false;
        end;


      procedure AddFilepos(const f : tfileposinfo);
        begin
          Setlength(PSearchNodeInfo(arg)^.warnedfilelocs,length(PSearchNodeInfo(arg)^.warnedfilelocs)+1);
          PSearchNodeInfo(arg)^.warnedfilelocs[high(PSearchNodeInfo(arg)^.warnedfilelocs)]:=f;
        end;


      { Checks if the symbol is a candidate for a warning.
        Emit warning/note for living locals, result and parameters, but only about the current
        symtables }
      function SymbolCandidateForWarningOrHint(sym : tabstractnormalvarsym) : Boolean;
        begin
          Result:=(((sym.owner=current_procinfo.procdef.localst) and
                    (current_procinfo.procdef.localst.symtablelevel=sym.owner.symtablelevel)
                   ) or
                   ((sym.owner=current_procinfo.procdef.parast) and
                    (sym.typ=paravarsym) and
                    (current_procinfo.procdef.parast.symtablelevel=sym.owner.symtablelevel) and
                    { all parameters except out parameters are initialized by the caller }
                    (tparavarsym(sym).varspez=vs_out)
                   ) or
                   ((vo_is_funcret in sym.varoptions) and
                    (current_procinfo.procdef.parast.symtablelevel=sym.owner.symtablelevel)
                   )
                  ) and
                  not(vo_is_external in sym.varoptions) and
                  not sym.inparentfpstruct and
                  not(vo_is_internal in sym.varoptions);
        end;

      var
        varsym : tabstractnormalvarsym;
        methodpointer,
        hpt : tnode;
      begin
        result:=fen_false;
        case n.nodetype of
          callparan:
            begin
              { do not warn about variables passed by var, just issue a hint, this
                is a workaround for old code e.g. using fillchar }
              if assigned(tcallparanode(n).parasym) and (tcallparanode(n).parasym.varspez in [vs_var,vs_out]) then
                begin
                  hpt:=tcallparanode(n).left;
                  while assigned(hpt) and (hpt.nodetype in [subscriptn,vecn,typeconvn]) do
                    hpt:=tunarynode(hpt).left;
                  if assigned(hpt) and (hpt.nodetype=loadn) and not(WarnedForLocation(hpt.fileinfo)) and
                    SymbolCandidateForWarningOrHint(tabstractnormalvarsym(tloadnode(hpt).symtableentry)) and
                    PSearchNodeInfo(arg)^.nodetosearch.isequal(hpt) then
                    begin
                      { issue only a hint for var, when encountering the node passed as out, we need only to stop searching }
                      if tcallparanode(n).parasym.varspez=vs_var then
                        UninitializedVariableMessage(hpt.fileinfo,false,
                          tloadnode(hpt).symtable.symtabletype=localsymtable,
                          is_managed_type(tloadnode(hpt).resultdef),
                          tloadnode(hpt).symtableentry.RealName);
                      AddFilepos(hpt.fileinfo);
                      result:=fen_norecurse_true;
                    end
                end;
            end;
          orn,
          andn:
            begin
              { take care of short boolean evaluation: if the expression to be search is found in left,
                we do not need to search right }
              if foreachnodestatic(pm_postprocess,taddnode(n).left,@optdfa.SearchNode,arg) or
                foreachnodestatic(pm_postprocess,taddnode(n).right,@optdfa.SearchNode,arg) then
                result:=fen_norecurse_true
              else
                result:=fen_norecurse_false;
            end;
          calln:
            begin
              methodpointer:=tcallnode(n).methodpointer;
              if assigned(methodpointer) and (methodpointer.nodetype<>typen) then
               begin
                  { Remove all postfix operators }
                  hpt:=methodpointer;
                  while assigned(hpt) and (hpt.nodetype in [subscriptn,vecn]) do
                    hpt:=tunarynode(hpt).left;

                 { skip (absolute and other simple) type conversions -- only now,
                   because the checks above have to take type conversions into
                   e.g. class reference types account }
                 hpt:=actualtargetnode(@hpt)^;

                  { R.Init then R will be initialized by the constructor,
                    Also allow it for simple loads }
                  if (tcallnode(n).procdefinition.proctypeoption=potype_constructor) or
                     (PSearchNodeInfo(arg)^.nodetosearch.isequal(hpt) and
                      (((methodpointer.resultdef.typ=objectdef) and
                        not(oo_has_virtual in tobjectdef(methodpointer.resultdef).objectoptions)) or
                       (methodpointer.resultdef.typ=recorddef)
                      )
                     ) then
                    begin
                      { don't warn about the method pointer }
                      AddFilepos(hpt.fileinfo);

                      if not(foreachnodestatic(pm_postprocess,tcallnode(n).left,@optdfa.SearchNode,arg)) then
                        foreachnodestatic(pm_postprocess,tcallnode(n).right,@optdfa.SearchNode,arg);
                      result:=fen_norecurse_true
                    end;
                 end;
            end;
          loadn:
            begin
              if (tloadnode(n).symtableentry.typ in [localvarsym,paravarsym,staticvarsym]) and
                PSearchNodeInfo(arg)^.nodetosearch.isequal(n) and ((nf_modify in n.flags) or not(nf_write in n.flags)) then
                begin
                  varsym:=tabstractnormalvarsym(tloadnode(n).symtableentry);

                  if assigned(varsym.owner) and SymbolCandidateForWarningOrHint(varsym) and
                     { the `zeroinit` modifier injects a Default() write for every
                       local at function entry, so reads are already initialised }
                     not(
                       (pio_zeroinit in current_procinfo.procdef.implprocoptions) and
                       (varsym.typ=localvarsym) and
                       (varsym.owner=current_procinfo.procdef.localst)
                     ) then
                    begin
                      if (vo_is_funcret in varsym.varoptions) and not(WarnedForLocation(n.fileinfo)) then
                        begin
                          if is_managed_type(varsym.vardef) then
                            MessagePos(n.fileinfo,sym_w_managed_function_result_uninitialized)
                          else
                            MessagePos(n.fileinfo,sym_w_function_result_uninitialized);
                          AddFilepos(n.fileinfo);
                          result:=fen_norecurse_true;
                        end
                      else
                        begin
                          { typed consts are initialized, further, warn only once per location }
                          if not (vo_is_typed_const in varsym.varoptions) and not(WarnedForLocation(n.fileinfo)) then
                            begin
                              UninitializedVariableMessage(n.fileinfo,true,varsym.typ=localvarsym,is_managed_type(varsym.vardef),varsym.realname);
                              AddFilepos(n.fileinfo);
                              result:=fen_norecurse_true;
                            end;
                        end;
                    end
{$ifdef dummy}
                  { if a the variable we are looking for is passed as a var parameter, we stop searching }
                  else if assigned(varsym.owner) and
                     (varsym.owner=current_procinfo.procdef.parast) and
                     (varsym.typ=paravarsym) and
                     (current_procinfo.procdef.parast.symtablelevel=varsym.owner.symtablelevel) and
                     (tparavarsym(varsym).varspez=vs_var) then
                    result:=fen_norecurse_true;
{$endif dummy}
                end;
            end;
          else
            ;
        end;
      end;


    { ----------------------------------------------------------------------
      Loop-fill false-positive suppression.

      The DFA models a partial element write  arr[i]:=x  as a full def of arr
      (see tvecnode/tsubscriptnode.mark_write, which propagate nf_write to the
      base load).  In straight-line code this makes  arr[3]:=x; y:=arr[0];  not
      warn.  Inside a for-loop, however, the for-node liveness handler re-adds
      the successor's whole life because the body "might run 0 times", so the
      classic idiom

        for i:=lo to hi do arr[i]:=...;    // fill
        for i:=lo to hi do ... arr[i] ...  // read, possibly several loops

      spuriously flags arr as "does not seem to be initialized" (this is a
      long-standing imprecision, present in upstream FPC 3.2.2 too).  It is a
      warning-only artefact: codegen stays conservative (arr keeps its
      register/init because it is live at entry), so nothing is miscompiled.

      LoopFillCovers recognises exactly this shape and suppresses the WARNING
      only (it never touches liveness / noregvarinitneeded, so it cannot cause
      a miscompile).  It is sound-precise rather than a blanket suppression: it
      fires only when EVERY access to the variable is  arr[c]  with c the
      counter of an enclosing for-loop, all those loops share syntactically
      identical bounds, and at least one of them writes arr[c] (a filler).
      Then every element that is read was written by the filler over the same
      index range, so the diagnostic is provably a false positive.  Any read
      not covered by such a matched fill (e.g. arr[k] with k not a matching
      loop counter) keeps warning as before. }

    type
      tloopfillrec = record
        sym : tsym;        { the variable under inspection }
        loopvar : tsym;    { counter of the loop currently being scanned }
        list : tfplist;    { collected base load nodes of sym[loopvar] }
        haswrite : boolean;{ some sym[loopvar] access is a write (filler) }
      end;
      ploopfillrec = ^tloopfillrec;

      tsymloadrec = record
        sym : tsym;
        list : tfplist;
      end;
      psymloadrec = ^tsymloadrec;

    function lf_stripconvs(n : tnode) : tnode;
      begin
        while assigned(n) and (n.nodetype=typeconvn) do
          n:=ttypeconvnode(n).left;
        result:=n;
      end;

    function lf_loopvarsym(f : tfornode) : tsym;
      var
        l : tnode;
      begin
        result:=nil;
        l:=lf_stripconvs(f.left);
        if assigned(l) and (l.nodetype=loadn) then
          result:=tloadnode(l).symtableentry;
      end;

    function lf_boundsequal(a,b : tfornode) : boolean;
      begin
        result:=((lnf_backward in a.loopflags)=(lnf_backward in b.loopflags)) and
                assigned(a.right) and assigned(b.right) and a.right.isequal(b.right) and
                assigned(a.t1) and assigned(b.t1) and a.t1.isequal(b.t1);
      end;

    { is n exactly  sym[loopvar]  (module type conversions) ? returns the base
      load node of sym, or nil }
    function lf_matched_base(n : tnode;sym,loopvar : tsym) : tnode;
      var
        b,idx : tnode;
      begin
        result:=nil;
        if n.nodetype<>vecn then
          exit;
        b:=lf_stripconvs(tvecnode(n).left);
        idx:=lf_stripconvs(tvecnode(n).right);
        if assigned(b) and (b.nodetype=loadn) and (tloadnode(b).symtableentry=sym) and
           assigned(idx) and (idx.nodetype=loadn) and (tloadnode(idx).symtableentry=loopvar) then
          result:=b;
      end;

    function lf_collect_forns(var n : tnode; arg : pointer) : foreachnoderesult;
      begin
        if n.nodetype=forn then
          tfplist(arg).Add(n);
        result:=fen_false;
      end;

    function lf_collect_symloads(var n : tnode; arg : pointer) : foreachnoderesult;
      begin
        if (n.nodetype=loadn) and (tloadnode(n).symtableentry=psymloadrec(arg)^.sym) then
          psymloadrec(arg)^.list.Add(n);
        result:=fen_false;
      end;

    function lf_collect_covered(var n : tnode; arg : pointer) : foreachnoderesult;
      var
        rec : ploopfillrec;
        b,lhs : tnode;
      begin
        result:=fen_false;
        rec:=ploopfillrec(arg);
        case n.nodetype of
          vecn:
            begin
              b:=lf_matched_base(n,rec^.sym,rec^.loopvar);
              if assigned(b) then
                begin
                  if rec^.list.IndexOf(b)<0 then
                    rec^.list.Add(b);
                  if nf_write in b.flags then
                    rec^.haswrite:=true;
                end;
            end;
          assignn:
            begin
              lhs:=lf_stripconvs(tassignmentnode(n).left);
              if assigned(lf_matched_base(lhs,rec^.sym,rec^.loopvar)) then
                rec^.haswrite:=true;
            end;
          callparan:
            begin
              if assigned(tcallparanode(n).parasym) and
                 (tcallparanode(n).parasym.varspez in [vs_var,vs_out]) then
                begin
                  lhs:=lf_stripconvs(tcallparanode(n).left);
                  if assigned(lf_matched_base(lhs,rec^.sym,rec^.loopvar)) then
                    rec^.haswrite:=true;
                end;
            end;
          else
            ;
        end;
      end;

    { collect into ploopfillrec.list every distinct local/static array symbol
      that appears as base of  sym[loopvar]  (rec^.loopvar) }
    function lf_collect_candidates(var n : tnode; arg : pointer) : foreachnoderesult;
      var
        rec : ploopfillrec;
        b : tnode;
        s : tsym;
        vardef : tdef;
      begin
        result:=fen_false;
        if n.nodetype<>vecn then
          exit;
        rec:=ploopfillrec(arg);
        b:=lf_stripconvs(tvecnode(n).left);
        if not(assigned(b) and (b.nodetype=loadn)) then
          exit;
        s:=tloadnode(b).symtableentry;
        if not(assigned(s) and (s.typ in [localvarsym,staticvarsym])) then
          exit;
        { index must be the loop counter }
        if lf_matched_base(n,s,rec^.loopvar)=nil then
          exit;
        vardef:=tabstractnormalvarsym(s).vardef;
        if not(assigned(vardef) and (vardef.typ=arraydef)) then
          exit;
        if rec^.list.IndexOf(s)<0 then
          rec^.list.Add(s);
      end;

    { Does the bound expression t reference the counter of a filler loop as
      loadn(fv)  or  loadn(fv)-1  with fv in fillervars?  Such a bound is
      provably <= the fill upper bound (the filler counter never exceeds its own
      top), so a reader loop nested in the filler with this "to" and the same
      "from" only reads already-filled indices. }
    function lf_le_filler_bound(t : tnode;fillervars : tfplist) : boolean;
      var
        b : tnode;
      begin
        result:=false;
        b:=lf_stripconvs(t);
        if not assigned(b) then
          exit;
        if (b.nodetype=loadn) and (fillervars.IndexOf(tloadnode(b).symtableentry)>=0) then
          result:=true
        else if (b.nodetype=subn) and
                (lf_stripconvs(taddnode(b).right).nodetype=ordconstn) and
                (tordconstnode(lf_stripconvs(taddnode(b).right)).value=1) then
          begin
            b:=lf_stripconvs(taddnode(b).left);
            result:=(b.nodetype=loadn) and (fillervars.IndexOf(tloadnode(b).symtableentry)>=0);
          end;
      end;

    { True if EVERY access to the local/static array variable sym in code is a
      matched loop-fill / loop-read shape (see the block comment above): every
      access is sym[c] with c the counter of a for-loop that either has bounds
      syntactically identical to the fill loop, or is nested in the fill loop
      with the same lower bound and an upper bound of  fillcounter  /
      fillcounter-1  (a subrange of the fill range).  At least one loop must
      write sym[c] (a filler).  forns must already hold every for-node of code.
      Then the DFA "not initialized" warning for sym is a false positive. }
    function LoopFillCovered(code : tnode;sym : tsym;forns : tfplist) : boolean;
      var
        covered,fillervars : tfplist;
        symloads : tsymloadrec;
        covrec : tloopfillrec;
        sig : tfornode;
        i,j : longint;
        f : tfornode;
        lv : tsym;
      begin
        result:=false;
        covered:=tfplist.Create;
        fillervars:=tfplist.Create;
        symloads.sym:=sym;
        symloads.list:=tfplist.Create;
        try
          { pass 1: locate the filler loop(s) and the shared fill range.  All
            fillers must agree on their bounds. }
          sig:=nil;
          for i:=0 to forns.Count-1 do
            begin
              f:=tfornode(forns[i]);
              lv:=lf_loopvarsym(f);
              if not assigned(lv) then
                continue;
              covrec.sym:=sym;
              covrec.loopvar:=lv;
              covrec.list:=tfplist.Create;
              covrec.haswrite:=false;
              foreachnodestatic(f.t2,@lf_collect_covered,@covrec);
              if (covrec.list.Count>0) and covrec.haswrite then
                begin
                  if sig=nil then
                    sig:=f
                  else if not lf_boundsequal(sig,f) then
                    begin
                      covrec.list.Free;
                      exit;   { fillers with different ranges -> keep warning }
                    end;
                  if fillervars.IndexOf(lv)<0 then
                    fillervars.Add(lv);
                end;
              covrec.list.Free;
            end;
          if sig=nil then
            exit;   { no filler -> keep warning }

          { pass 2: every access loop must be a covered shape, and we collect the
            base loads it covers }
          for i:=0 to forns.Count-1 do
            begin
              f:=tfornode(forns[i]);
              lv:=lf_loopvarsym(f);
              if not assigned(lv) then
                continue;
              covrec.sym:=sym;
              covrec.loopvar:=lv;
              covrec.list:=tfplist.Create;
              covrec.haswrite:=false;
              foreachnodestatic(f.t2,@lf_collect_covered,@covrec);
              if covrec.list.Count>0 then
                begin
                  if not(lf_boundsequal(sig,f) or
                         (assigned(f.right) and assigned(sig.right) and
                          f.right.isequal(sig.right) and
                          lf_le_filler_bound(f.t1,fillervars))) then
                    begin
                      covrec.list.Free;
                      exit;   { uncovered index range -> keep warning }
                    end;
                  for j:=0 to covrec.list.Count-1 do
                    if covered.IndexOf(covrec.list[j])<0 then
                      covered.Add(covrec.list[j]);
                end;
              covrec.list.Free;
            end;

          { every load of sym must be a covered sym[matching-loopvar] access }
          foreachnodestatic(code,@lf_collect_symloads,@symloads);
          result:=true;
          for i:=0 to symloads.list.Count-1 do
            if covered.IndexOf(symloads.list[i])<0 then
              begin
                result:=false;
                break;
              end;
        finally
          covered.Free;
          fillervars.Free;
          symloads.list.Free;
        end;
      end;


    procedure CollectLoopFillCoveredSyms(code : tnode;syms : tfplist);
      var
        forns : tfplist;
        candrec : tloopfillrec;
        i,j : longint;
        f : tfornode;
        lv : tsym;
        s : tsym;
      begin
        if not assigned(code) then
          exit;
        forns:=tfplist.Create;
        candrec.list:=tfplist.Create;   { candidate symbols }
        try
          foreachnodestatic(code,@lf_collect_forns,forns);
          if forns.Count=0 then
            exit;
          { gather candidate variables: any sym written/read as sym[loopvar] }
          for i:=0 to forns.Count-1 do
            begin
              f:=tfornode(forns[i]);
              lv:=lf_loopvarsym(f);
              if not assigned(lv) then
                continue;
              candrec.sym:=nil;
              candrec.loopvar:=lv;
              foreachnodestatic(f.t2,@lf_collect_candidates,@candrec);
            end;
          { test each candidate }
          for j:=0 to candrec.list.Count-1 do
            begin
              s:=tsym(candrec.list[j]);
              if (syms.IndexOf(s)<0) and LoopFillCovered(code,s,forns) then
                syms.Add(s);
            end;
        finally
          forns.Free;
          candrec.list.Free;
        end;
      end;


    procedure CheckAndWarn(code : tnode;nodetosearch : tnode);

      var
        SearchNodeInfo : TSearchNodeInfo;

      function DoCheck(node : tnode) : boolean;
        var
          i : longint;
          touchesnode : Boolean;

        procedure MaybeDoCheck(n : tnode);inline;
          begin
            Result:=Result or DoCheck(n);
          end;

        procedure MaybeSearchIn(n : tnode);
          begin
            if touchesnode then
              Result:=Result or foreachnodestatic(pm_postprocess,n,@SearchNode,@SearchNodeInfo);
          end;

        begin
          result:=false;

          if node=nil then
            exit;

          if tnf_processing in node.transientflags then
            exit;
          include(node.transientflags,tnf_processing);

          if not(assigned(node.optinfo)) or not(DynSetIn(node.optinfo^.life,nodetosearch.optinfo^.index)) then
            exit;

          { we do not need this info always, so try to safe some time here, CheckAndWarn
            takes a lot of time anyways }
          if not(node.nodetype in [statementn,blockn]) then
            touchesnode:=DynSetIn(node.optinfo^.use,nodetosearch.optinfo^.index) or
              DynSetIn(node.optinfo^.def,nodetosearch.optinfo^.index)
          else
            touchesnode:=false;

          case node.nodetype of
            whilerepeatn:
              begin
                MaybeSearchIn(twhilerepeatnode(node).left);
                MaybeDoCheck(twhilerepeatnode(node).right);
              end;

            forn:
              begin
                MaybeSearchIn(tfornode(node).right);
                MaybeSearchIn(tfornode(node).t1);
                MaybeDoCheck(tfornode(node).t2);
              end;

            statementn:
              MaybeDoCheck(tstatementnode(node).statement);

            blockn:
              MaybeDoCheck(tblocknode(node).statements);

            ifn:
              begin
                MaybeSearchIn(tifnode(node).left);
                MaybeDoCheck(tifnode(node).right);
                MaybeDoCheck(tifnode(node).t1);
              end;

            casen:
              begin
                MaybeSearchIn(tcasenode(node).left);
                for i:=0 to tcasenode(node).blocks.count-1 do
                  MaybeDoCheck(pcaseblock(tcasenode(node).blocks[i])^.statement);

                MaybeDoCheck(tcasenode(node).elseblock);
              end;

            { we are aware of the following nodes so if new node types are added to the compiler
              and pop up in the search, the ie below kicks in as a reminder }
            exitn:
              begin
                MaybeSearchIn(texitnode(node).left);
                { exit uses the resultnode implicitly, so searching for a matching node is
                  useless, if we reach the exit node and found the living node not in left, then
                  it can be only the resultnode

                  successor might be assigned in case of an inlined exit node, in this case we do not warn about an unassigned
                  result as this had happened already when the routine has been compiled }
                if not(assigned(node.successor)) and not(Result) and not(is_void(current_procinfo.procdef.returndef)) and
                  not(assigned(texitnode(node).resultexpr)) and
                  { don't warn about constructors }
                  not(current_procinfo.procdef.proctypeoption in [potype_class_constructor,potype_constructor]) then
                  begin
                    if is_managed_type(current_procinfo.procdef.returndef) then
                      MessagePos(node.fileinfo,sym_w_managed_function_result_uninitialized)
                    else
                      MessagePos(node.fileinfo,sym_w_function_result_uninitialized);

                    Setlength(SearchNodeInfo.warnedfilelocs,length(SearchNodeInfo.warnedfilelocs)+1);
                    SearchNodeInfo.warnedfilelocs[high(SearchNodeInfo.warnedfilelocs)]:=node.fileinfo;
                  end
              end;
            { could be the implicitly generated load node for the result }
{$ifdef JVM}
            { all other platforms except jvm translate raise nodes into call nodes during pass_1 }
            raisen,
{$endif JVM}
            labeln,
            loadn,
            assignn,
            calln,
            temprefn,
            typeconvn,
            inlinen,
            tempcreaten,
            { autovectorizer body node: search its vecn/scalar children for a use
              of the variable exactly like a call/assignment (a[i] written,
              b[i]/c[i]/scalar read) }
            vectoropn,
            tempdeleten:
              MaybeSearchIn(node);
            nothingn,
            continuen,
            goton,
            breakn:
              ;
            else
              internalerror(2013111301);
          end;

          { if already a warning has been issued, then stop }
          if Result then
            exit;

          if assigned(node.successor) then
            MaybeDoCheck(node.successor);
        end;

      begin
        SearchNodeInfo.nodetosearch:=nodetosearch;
        DoCheck(code);
        foreachnodestatic(pm_postprocess,code,@ResetProcessing,nil);
      end;


end.
