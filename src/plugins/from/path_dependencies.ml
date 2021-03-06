(* Modified by TrustInSoft *)

(**************************************************************************)
(*                                                                        *)
(*  This file is part of Frama-C.                                         *)
(*                                                                        *)
(*  Copyright (C) 2007-2015                                               *)
(*    CEA (Commissariat à l'énergie atomique et aux énergies              *)
(*         alternatives)                                                  *)
(*                                                                        *)
(*  you can redistribute it and/or modify it under the terms of the GNU   *)
(*  Lesser General Public License as published by the Free Software       *)
(*  Foundation, version 2.1.                                              *)
(*                                                                        *)
(*  It is distributed in the hope that it will be useful,                 *)
(*  but WITHOUT ANY WARRANTY; without even the implied warranty of        *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the         *)
(*  GNU Lesser General Public License for more details.                   *)
(*                                                                        *)
(*  See the GNU Lesser General Public License version 2.1                 *)
(*  for more details (enclosed in the file licenses/LGPLv2.1).            *)
(*                                                                        *)
(**************************************************************************)

open Cil_types
open Cil
open Cil_datatype
open Locations

module StmtToZone = Stmt.Hashtbl.Make(Zone)

module PathdepsData =
  Kernel_function.Make_Table
    (StmtToZone)
    (struct
      let name = "Path dependencies"
      let size = 13
      let dependencies = [ Db.Value.self ]
    end)

type analysis_state = {
  current_function : Kernel_function.t;
  callsite : Kinstr.t;
  table_for_calls :
    Zone.t Stmt.Hashtbl.t Kernel_function.Hashtbl.t Kinstr.Hashtbl.t
}

let analysis_stack : analysis_state list ref = ref []

let merge_stmt_zone dest src =
  Stmt.Hashtbl.iter (fun stmt zone ->
      try
        Stmt.Hashtbl.replace dest stmt
          (Zone.join zone (Stmt.Hashtbl.find dest stmt))
      with Not_found ->
        Stmt.Hashtbl.add dest stmt zone
    ) src

let merge_pathdeps kf_tbl =
  Kernel_function.Hashtbl.iter (fun kf stmt_tbl ->
      try
        let old = PathdepsData.find kf in
        merge_stmt_zone old stmt_tbl
      with Not_found ->
        PathdepsData.add kf (Cil_datatype.Stmt.Hashtbl.copy stmt_tbl)
    ) kf_tbl

let merge_kernel_functions dest src =
  Kernel_function.Hashtbl.iter (fun kf stmt_tbl ->
      try
        let old = Kernel_function.Hashtbl.find dest kf in
        merge_stmt_zone old stmt_tbl
      with Not_found ->
        Kernel_function.Hashtbl.add dest kf stmt_tbl
    ) src

let add_to_table_for_calls table_for_calls callsite data =
  try
    let prev = Kinstr.Hashtbl.find table_for_calls callsite in
    merge_kernel_functions prev data
  with Not_found ->
    Kinstr.Hashtbl.add table_for_calls callsite data

let make_kf_tbl kf stmt_tbl =
  let tbl = Kernel_function.Hashtbl.create 1 in
  Kernel_function.Hashtbl.add tbl kf stmt_tbl;
  tbl


class do_pathdeps froms get_stmt_state callwise_state_with_formals
    callstack_table =
object(self)
  inherit Cil.nopCilVisitor
  val mutable inputs : Zone.t Stmt.Hashtbl.t = Stmt.Hashtbl.create 13

  method result = inputs

  method join stmt zone =
    if not (Zone.is_bottom zone) then begin
      let table = Stmt.Hashtbl.create 13 in
      Stmt.Hashtbl.add table stmt zone;
      merge_stmt_zone self#result table
    end

  method! vstmt s =
    if Db.Value.is_reachable (get_stmt_state (Extlib.the self#current_stmt))
    then begin
      match s.skind with
      | UnspecifiedSequence seq ->
        List.iter
          (fun (stmt,_,_,_,_) ->
            ignore (visitCilStmt (self:>cilVisitor) stmt))
          seq;
        SkipChildren (* do not visit the additional lvals *)
      | If (_cond, _th, _el, _) ->
        DoChildren (* for _cond and for the statements in _th, _el *)
      | Loop _ | Block _ ->
        DoChildren (* for the statements *)
      | Switch _ ->
        DoChildren (* for the statements and the expression *)
      | Instr _ ->
        DoChildren (* for Calls *)
      | Return _ | Goto _ | Break _ | Continue _ | Throw _ ->
        SkipChildren
      | TryExcept _ | TryFinally _ | TryCatch _ -> assert false
    end
    else SkipChildren

  method stmt_froms =
    let stmt = Extlib.the (self#current_stmt) in
    Stmt.Hashtbl.find froms stmt

  method! vlval lv =
    let stmt  = Extlib.the self#current_stmt in
    let state = get_stmt_state stmt in
    let deps, z, _exact =
      !Db.Value.lval_to_zone_with_deps_state
        ~for_writing:false
        ~deps:(Some Zone.bottom)
        state
        lv
    in
    let all = Zone.join z deps in
    begin try
        let froms = self#stmt_froms in
        let all_f = Function_Froms.Memory.find froms all in
        self#join stmt all_f;
      with Not_found ->
        ()
    end;
    SkipChildren

  method! vinst i =
    let current_stmt = Extlib.the self#current_stmt in
    let stmt_state   = get_stmt_state current_stmt  in
    if Db.Value.is_reachable stmt_state
    then begin match i with
      | Call (_, expr, _, _) ->
        let deps_callees, _kfset =
          !Db.Value.expr_to_kernel_function_state
            ~deps:(Some Zone.bottom)
            stmt_state expr
        in
        let froms_state = Stmt.Hashtbl.find froms current_stmt in
        let deps_callees =
          Function_Froms.Memory.find froms_state deps_callees
        in
        let dependencies_by_function =
          Stmt.Hashtbl.find callwise_state_with_formals current_stmt
        in
        let kf_tbl =
          Kinstr.Hashtbl.find callstack_table (Kstmt current_stmt)
        in
        List.iter (fun (kf, state) ->
	    if not (!Db.Value.use_spec_instead_of_definition kf) then begin
              let stmt_tbl = Kernel_function.Hashtbl.find kf_tbl kf in
              Stmt.Hashtbl.iter (fun stmt zone ->
                  self#join stmt (Function_Froms.Memory.find state zone)
                ) stmt_tbl
            end else
              Format.printf
                "Assuming library function %a has no path dependencies@."
	        Kernel_function.pretty kf
          ) dependencies_by_function;
        self#join current_stmt deps_callees;
        SkipChildren
      | _ ->
        SkipChildren
    end
    else SkipChildren

  method! vexpr exp =
    match exp.enode with
    | AddrOf lv | StartOf lv ->
      let current_stmt = Extlib.the self#current_stmt in
      let deps, _loc =
        !Db.Value.lval_to_loc_with_deps (* loc ignored *)
          ~with_alarms:CilE.warn_none_mode
          ~deps:Zone.bottom
          (Kstmt current_stmt)
          lv
      in
      let froms = self#stmt_froms in
      let deps_f = Function_Froms.Memory.find froms deps in
      self#join current_stmt deps_f;
      SkipChildren
    | _ -> DoChildren

end

let is_constant c =
  c = (false, true) || c = (true, false)

(* Use by from_register before writing the log. *)
let finalize () =
  PathdepsData.iter (fun kf tbl ->
      Stmt.Hashtbl.iter (fun stmt _ ->
          if (is_constant (Db.Value.condition_truth_value stmt)) then
            Stmt.Hashtbl.remove tbl stmt
        ) tbl;
      if Stmt.Hashtbl.length tbl = 0 then
        PathdepsData.remove kf
    );
  PathdepsData.mark_as_computed ()

let register_in_stack (_, callstack) =
  let current_function, callsite = List.hd callstack in
  if not (!Db.Value.use_spec_instead_of_definition current_function) &&
     Kernel_function.is_definition current_function then
    analysis_stack :=
      { current_function;
        callsite;
        table_for_calls = Kinstr.Hashtbl.create 3 } :: !analysis_stack
  else match !analysis_stack with
    | { table_for_calls } :: _ ->
      (* Add declaration with empty table to table avoids some Not_found
         exception when calling the visitor. *)
      Kinstr.Hashtbl.add
        table_for_calls callsite (Kernel_function.Hashtbl.create 0)
    | _ -> () (* main function is not defined. *)

let compute_pathdeps (stack, froms,
                      callwise_state_with_formals, get_stmt_state) =
  let kf = Stack.top stack in
  match !analysis_stack with
  | { current_function; callsite; table_for_calls }
      :: ({ table_for_calls = table } :: _ as tail) ->
    assert (Kernel_function.compare kf current_function = 0);
    analysis_stack := tail;
    begin match kf.fundec with
      | Definition (f, _) ->
        let computer =
          new do_pathdeps froms get_stmt_state
            callwise_state_with_formals table_for_calls
        in
        ignore (visitCilFunction (computer :> cilVisitor) f);
        let data = computer#result in
        let kf_table = make_kf_tbl kf data in
        add_to_table_for_calls table callsite kf_table;
        merge_pathdeps kf_table
      | Declaration _ ->
        assert false
    end

  | _ ->
    analysis_stack := []

let () =
  Cmdline.run_after_configuring_stage
    (fun () ->
      if From_parameters.PathDeps.get ()
      then begin
        Db.Value.Call_Value_Callbacks.extend_once register_in_stack;
        Db.From.Record_From_Callbacks.extend_once compute_pathdeps;
        Db.From.PathDeps.iter := PathdepsData.iter;
        Db.From.PathDeps.find := PathdepsData.find;
      end
    )


(*
Local Variables:
compile-command: "make -C ../../.."
End:
*)

