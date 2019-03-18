(** Terminating top down solver that only keeps values at widening points and restores other values afterwards. *)

open Prelude
open Analyses
open Constraints
open Messages

let debug_now = ref false

let result_file_name = "td3.data" 

module WP =

  functor (S:EqConstrSys) ->
  functor (HM:Hash.H with type key = S.v) ->
  struct
    module KeySet = Set.Make (struct type t = S.Var.t let compare = S.Var.compare end)
    include Generic.SolverStats (S)
    module VS = Set.Make (S.Var)

    module P =
    struct
      type t = S.Var.t * S.Var.t
      let equal (x1,x2) (y1,y2) = S.Var.equal x1 y1 && S.Var.equal x2 y2
      let hash  (x1,x2)         = (S.Var.hash x1 * 13) + S.Var.hash x2
    end

    type phase = Widen | Narrow

    let solve_count = ref 0

    let solve box st vs infl rho called wpoint stable =
      let term  = GobConfig.get_bool "exp.solver.td3.term" in
      let space = GobConfig.get_bool "exp.solver.td3.space" in
      let cache = GobConfig.get_bool "exp.solver.td3.space_cache" in

      print_endline ("Start solve with infl="^string_of_int (HM.length infl)^"
       rho="^string_of_int (HM.length rho)^"
       called="^string_of_int (HM.length called)^"
       wpoint="^string_of_int (HM.length wpoint)
        );

(*       let stable = HM.create  10 in
 *)(*       let infl   = HM.create  10 in (* y -> xs *) *)
(*       let called = HM.create  10 in
 *)(*       let rho    = HM.create  10 in*)
(*       let wpoint = HM.create  10 in
 *)      let cache_sizes = ref [] in

      let add_infl y x =
        if tracing then trace "sol2" "add_infl %a %a\n" S.Var.pretty_trace y S.Var.pretty_trace x;
        HM.replace infl y (VS.add x (try HM.find infl y with Not_found -> VS.empty))
      in
      let rec destabilize x =
        if tracing then trace "sol2" "destabilize %a on %i\n" S.Var.pretty_trace x (S.Var.line_nr x);
        let w = HM.find_default infl x VS.empty in
        HM.replace infl x VS.empty;
        VS.iter (fun y -> HM.remove stable y; if not (HM.mem called y) then destabilize y) w
      and solve x phase =
        solve_count := !solve_count + 1;
        if tracing then trace "sol2" "solve %a on %i, called: %b, stable: %b\n" S.Var.pretty_trace x (S.Var.line_nr x) (HM.mem called x) (HM.mem stable x);
        init x;
        assert (S.system x <> None);
        if not (HM.mem called x || HM.mem stable x) then (
          HM.replace stable x ();
          HM.replace called x ();
          let wp = space && HM.mem rho x || HM.mem wpoint x in
          let old = HM.find rho x in
          let l = HM.create 10 in
          let tmp = eq x (eval l x) side in
          if tracing then trace "sol" "Var: %a\n" S.Var.pretty_trace x ;
          if tracing then trace "sol" "Contrib:%a\n" S.Dom.pretty tmp;
          HM.remove called x;
          let tmp =
            if not wp then tmp
            else
              if term then
                match phase with Widen -> S.Dom.widen old (S.Dom.join old tmp) | Narrow -> S.Dom.narrow old tmp
              else
                box x old tmp
          in
          if tracing then trace "cache" "cache size %d for %a on %i\n" (HM.length l) S.Var.pretty_trace x (S.Var.line_nr x);
          cache_sizes := HM.length l :: !cache_sizes;
          if not (S.Dom.equal old tmp) then (
            update_var_event x old tmp;
            if tracing then trace "sol" "New Value:%a\n\n" S.Dom.pretty tmp;
            HM.replace rho x tmp;
            destabilize x;
            (solve[@tailcall]) x phase;
          ) else if not (HM.mem stable x) then (
            (solve[@tailcall]) x Widen;
          ) else if term && phase = Widen then (
            (* HM.remove stable x;
            (solve[@tailcall]) x Narrow; *)
          );
        )
      and eq x get set =
        if tracing then trace "sol2" "eq %a on %i\n" S.Var.pretty_trace x (S.Var.line_nr x);
        eval_rhs_event x;
        match S.system x with
        | None -> S.Dom.bot ()
        | Some f -> f get set
      and simple_solve l x y =
        if tracing then trace "sol2" "simple_solve %a on %i (rhs: %b)\n" S.Var.pretty_trace y (S.Var.line_nr y) (S.system y <> None);
        if S.system y = None then (init y; HM.find rho y) else
        if HM.mem rho y || not space then (solve y Widen; HM.find rho y) else
        if HM.mem called y then (init y; HM.remove l y; HM.find rho y) else
        (* if HM.mem called y then (init y; let y' = HM.find_default l y (S.Dom.bot ()) in HM.replace rho y y'; HM.remove l y; y') else *)
        if cache && HM.mem l y then HM.find l y
        else (
          HM.replace called y ();
          let tmp = eq y (eval l x) side in
          HM.remove called y;
          if HM.mem rho y then (HM.remove l y; solve y Widen; HM.find rho y)
          else (if cache then HM.replace l y tmp; tmp)
        )
      and eval l x y =
        if tracing then trace "sol2" "eval %a on %i ## %a on %i\n" S.Var.pretty_trace x (S.Var.line_nr x) S.Var.pretty_trace y (S.Var.line_nr y);
        get_var_event y;
        if not space && HM.mem called y then HM.replace wpoint y ();
        let tmp = simple_solve l x y in
        if HM.mem rho y then add_infl y x;
        tmp
      and side y d = (* only to variables y w/o rhs *)
        if tracing then trace "sol2" "side to %a on %i (wpx: %b) ## value: %a\n" S.Var.pretty_trace y (S.Var.line_nr y) (HM.mem rho y) S.Dom.pretty d;
        if S.system y <> None then (
          ignore @@ Pretty.printf "side-effect to unknown w/ rhs: %a, contrib: %a\n" S.Var.pretty_trace y S.Dom.pretty d;
        );
        assert (S.system y = None);
        init y;
        let old = HM.find rho y in
        if not (S.Dom.leq d old) then (
          let j = S.Dom.join old d in
          let w = S.Dom.widen old j in
          let fail reason a b =
            if not (S.Dom.leq a b) then
              ignore @@ Pretty.printf "FAIL (%s): %a is not leq %a. old: %a, d: %a\n" reason S.Dom.pretty a S.Dom.pretty b S.Dom.pretty old S.Dom.pretty d in
          fail "old j" old j;
          fail "old w" old w;
          fail "j w" j w;
          (* assert (S.Dom.leq old j);
          assert (S.Dom.leq old w);
          assert (S.Dom.leq j w); *)
          HM.replace rho y (S.Dom.widen old (S.Dom.join old d));
          HM.replace stable y ();
          destabilize y
        )
      and init x =
        if tracing then trace "sol2" "init %a on %i\n" S.Var.pretty_trace x (S.Var.line_nr x);
        if not (HM.mem rho x) then (
          new_var_event x;
          HM.replace rho x (S.Dom.bot ())
        )
      in

      let set_start (x,d) =
        if tracing then trace "sol2" "set_start %a on %i ## %a\n" S.Var.pretty_trace x (S.Var.line_nr x) S.Dom.pretty d;
        init x;
        HM.replace rho x d;
        HM.replace stable x ();
        (* solve x Widen *)
      in

      start_event ();
      let obsolete_funs = List.filter (fun g -> match g with Cil.GFun _ -> true | _ -> false) S.I.obsolete in
      let obsolete_funs = List.map (fun g -> match g with Cil.GFun (f, l) -> f | _ -> raise (Failure "Cannot happen")) obsolete_funs in

      List.iter (fun a -> print_endline @@ "Destabilizing " ^ a.Cil.svar.vname ) obsolete_funs;
      let obsolete = Set.of_list (List.map (fun a -> "fun" ^ (string_of_int a.Cil.svar.vid))  obsolete_funs) in
      let nodes_to_delete (functions: Cil.fundec list) =
        let nodes = Hashtbl.create 103 in
        let add_stmts (f: Cil.fundec) =
          List.iter (fun s -> Hashtbl.replace nodes (string_of_int s.Cil.sid) ()) (f.sallstmts)
        in
        List.iter (fun f -> Hashtbl.replace nodes ("fun"^(string_of_int f.Cil.svar.vid)) (); Hashtbl.replace nodes ("ret"^(string_of_int f.Cil.svar.vid)) (); add_stmts f) functions;
        nodes
      in
      let marked_for_deletion = nodes_to_delete obsolete_funs in
      Set.iter (fun k  -> print_endline k) obsolete;
      print_endline @@ "Obsolete: " ^ string_of_int (Set.cardinal obsolete);
      HM.iter (fun k v -> print_endline @@ "Checking: " ^(S.Var.var_id k); if Set.mem (S.Var.var_id k) obsolete then (print_endline ("destabilizing " ^ S.Var.var_id k); destabilize k)) stable;
      let delete_marked = HM.iter (fun k v -> if Hashtbl.mem  marked_for_deletion (S.Var.var_id k) then HM.remove rho k ) in
      let delete_marked1 = HM.iter (fun k v -> if Hashtbl.mem  marked_for_deletion (S.Var.var_id k) then HM.remove rho k ) in
      let delete_marked2 = HM.iter (fun k v -> if Hashtbl.mem  marked_for_deletion (S.Var.var_id k) then HM.remove rho k ) in
      
      print_endline ("rho, infl, wpoint: " ^ string_of_int (HM.length rho) ^ ", "^ string_of_int (HM.length rho) ^ ", " ^ string_of_int (HM.length rho) ^ ", " );
      delete_marked rho;
      delete_marked1 infl;
      delete_marked2 wpoint;
      print_endline ("rho, infl, wpoint: " ^ string_of_int (HM.length rho) ^ ", "^ string_of_int (HM.length rho) ^ ", " ^ string_of_int (HM.length rho) ^ ", " );

      List.iter set_start st;
      List.iter init vs;
      List.iter (fun x -> solve x Widen) vs;
      (* iterate until there are no unstable variables
       * after termination, only those variables are stable which are
       * - reachable from any of the queried variables vs, or
       * - effected by side-effects and have no constraints on their own (this should be the case for all of our analyses)
       *)
      let rec solve_sidevs () =
        let non_stable = HM.fold (fun k _ a -> if S.system k <> None && not (HM.mem stable k) then k::a else a) rho [] in
        if non_stable <> [] then (
          List.iter (fun x -> solve x Widen) non_stable;
          solve_sidevs ()
        )
      in
      solve_sidevs ();

      (* print_endline ("End solve before reach with infl="^string_of_int (HM.length infl)^"
       rho="^string_of_int (HM.length rho)^"
       called="^string_of_int (HM.length called)^"
       wpoint="^string_of_int (HM.length wpoint)
        ); *)

      (* verifies values at widening points and adds values for variables in-between *)
      let visited = HM.create 10 in
      let rec get x =
       if HM.mem visited x then (
          if not (HM.mem rho x) then (
            ignore @@ Pretty.printf "TDFP Found an unknown that should be a widening point: %a\n" S.Var.pretty_trace x;
            S.Dom.bot ()
          ) else
            HM.find rho x
        ) else (
          HM.replace visited x ();
          let check_side y d =
            let mem = HM.mem rho y in
            let d' = try HM.find rho y with Not_found -> S.Dom.bot () in
            if not (S.Dom.leq d d') then ignore @@ Pretty.printf "TDFP Fixpoint not reached in restore step at side-effected variable (mem: %b) %a from %a: %a not leq %a\n" mem S.Var.pretty_trace y S.Var.pretty_trace x S.Dom.pretty d S.Dom.pretty d'
          in
          let eq x =
            match S.system x with
            | None -> if HM.mem rho x then HM.find rho x else S.Dom.bot ()
            | Some f -> f get check_side
          in
          if HM.mem rho x then (
            if not (HM.mem stable x) && S.system x <> None then ignore @@ Pretty.printf "TDFP Found an unknown in rho that should be stable: %a\n" S.Var.pretty_trace x;
            let d1 = HM.find rho x in
            let d2 = eq x in
            if not (S.Dom.leq d2 d1) then
              ignore @@ Pretty.printf "TDFP Fixpoint not reached in restore step at %a (%s:%d)\n  @[Variable:\n%a\nRight-Hand-Side:\n%a\nCalculating one more step changes: %a\n@]" S.Var.pretty_trace x (S.Var.file_name x) (S.Var.line_nr x) S.Dom.pretty d1 S.Dom.pretty d2 S.Dom.pretty_diff (d1,d2);
            d1
          ) else (
            let d = eq x in
            (* assert(not (S.Dom.is_bot d)); *)
            HM.replace rho x d;
            d
          )
        )
      in
      (* restore values for non-widening-points *)
      if space && GobConfig.get_bool "exp.solver.wp.restore" then (
        if (GobConfig.get_bool "dbg.verbose") then
          print_endline ("Restoring missing values.");
        let restore () =
          let get x =
            let d = get x in
            if tracing then trace "sol2" "restored var %a on %i ## %a\n" S.Var.pretty_trace x  (S.Var.line_nr x) S.Dom.pretty d
          in
          List.iter get vs;
          HM.iter (fun x v -> if not (HM.mem visited x) then HM.remove rho x) rho
        in
        Stats.time "restore" restore ();
        if (GobConfig.get_bool "dbg.verbose") then ignore @@ Pretty.printf "Solved %d vars. Total of %d vars after restore.\n" !Goblintutil.vars (HM.length rho);
      );
   (*    let avg xs = float_of_int (BatList.sum xs) /. float_of_int (List.length xs) in
      if tracing then trace "cache" "#caches: %d, max: %d, avg: %.2f\n" (List.length !cache_sizes) (List.max !cache_sizes) (avg !cache_sizes);
 *)
      (* let reachability xs =
        let reachable = HM.create (HM.length rho) in
        let rec one_var x =
          if not (HM.mem reachable x) then (
            HM.replace reachable x ();
            match S.system x with
            | None -> ()
            | Some x -> one_constraint x
          )
        and one_constraint f =
          ignore (f (fun x -> one_var x; try HM.find rho x with Not_found -> S.Dom.bot ()) (fun x _ -> one_var x))
        in
        List.iter one_var xs;
        HM.iter (fun x v -> if not (HM.mem reachable x) then HM.remove rho x) rho;
      in
      reachability vs; *)

      stop_event ();

      print_endline ("End solve & reach with infl="^string_of_int (HM.length infl)^"
       rho="^string_of_int (HM.length rho)^"
       called="^string_of_int (HM.length called)^"
       wpoint="^string_of_int (HM.length wpoint)
        );

(*       HM.iter (fun key vl ->  (print_int (S.Var.line_nr key); print_string " "; print_string (S.Var.file_name key); print_string ((S.Var.var_id key)^ " "));  print_newline ()) rho;
 *)      let sum = HM.fold (fun key vl acc -> acc +1 ) rho 0 in
      print_string "Number of elemnts in rho: ";
      print_int sum;
      print_newline ();
(*       HM.clear stable;
 *)   
      print_string "Called solve: ";
      print_int !solve_count;
      print_endline " times";
      solve_count := 0;
(*       HM.clear infl  ;
 *)
      (infl, rho, called, wpoint, stable)

      let solve box st vs =
        let file_in = Filename.concat S.I.analyzed_commit_dir result_file_name in
        let (infl, rho, called, wpoint, stable) as input_data =  if Sys.file_exists file_in
                                            then Serialize.unmarshall file_in
                                            else (HM.create 10, HM.create 10, HM.create 10, HM.create 10, HM.create 10) in
        let varCountBefore = HM.length rho in                                            
        let (infl, rho1, called, wpoint, stable) = solve box st vs infl rho called wpoint stable in
        let varCountAfter = HM.length rho1 in

        let path = Goblintutil.create_dir S.I.current_commit_dir in
        if Sys.file_exists path then (
          let file_out = Filename.concat S.I.current_commit_dir result_file_name in
          Serialize.marshall (infl, rho1, called, wpoint, stable) file_out;
        );
        print_endline ("number of different vars: " ^ string_of_int (varCountAfter - varCountBefore));
        rho1


  end

let _ =
  let module WP = GlobSolverFromIneqSolver (SLR.JoinContr (WP)) in
  Selector.add_solver ("td3", (module WP : GenericGlobSolver));