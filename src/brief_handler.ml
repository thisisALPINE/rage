open Core.Std
open Utils
open Sexplib.Std

(* types of the url input arguments *)
type cols_t = (string * string list) list list with sexp
type rows_t = (string * string list) list list with sexp
type base_t = (string * string list) list with sexp
type baseline_t = int with sexp
type ctx_t  = (string * string list) list with sexp
type str_lst_t = string list with sexp
type out_t  = [`Html | `Wiki] with sexp
type sort_by_col_t = int with sexp

type result_t = Avg of float | Range of float * float * float

let t ~args = object (self)
  inherit Html_handler.t ~args

  method private write_body =

    let progress str =
(*
      printf "%s%!" str;
      flush stdout;
*)
      ()
    in

    (* === input === *)

    let brief_id = try List.Assoc.find_exn params "id" with |_->"" in
    let args =
      if brief_id = "" then params
      else
        let brief_params_of_id id =
          let query = sprintf "select brief_params from briefs where brief_id='%s'" id in
          (Sql.exec_exn ~conn ~query)#get_all.(0).(0)
        in
        let replace kvs overrides =
          List.fold_left kvs ~init:[] ~f:(fun acc (k,v)->match List.find overrides ~f:(fun (ko,_)->k=ko) with|None->(k,v)::acc|Some o->o::acc)
        in
        let replaced = 
          (replace 
            (List.map ~f:(fun p->let ls=String.split ~on:'=' p in (List.nth_exn ls 0),(List.nth_exn ls 1)) (String.split ~on:'&' (brief_params_of_id brief_id) ))
            params (* if params present, use it preferrably over the args in the db *)
          )
        in
        List.fold_left params ~init:replaced ~f:(fun acc (k,v)->
          match List.find acc ~f:(fun (ka,_)->k=ka) with
          |None->(k,v)::acc (* if params contains a k not in the db, add this k to args *)
          |Some _->acc
        )
    in
    let url_decode url = (* todo: find a more complete version in some lib *)
      List.fold_left
         [
           ("%20"," ");("%22","\""); ("%28","("); ("%29",")");   (* unescape http params *)
         ]
         ~init:url
        ~f:(fun acc (f,t)->(Str.global_replace (Str.regexp f) t acc)) (* f->t *)
    in
    let params_cols=(try url_decode (List.Assoc.find_exn args "cols") with |_-> "") in
    let params_rows=(try url_decode (List.Assoc.find_exn args "rows") with |_-> "") in
    let params_base=(try url_decode (List.Assoc.find_exn args "base") with |_-> "") in
    let params_baseline=(try url_decode (List.Assoc.find_exn args "baseline") with |_-> "") in
    let params_out=(try url_decode (List.Assoc.find_exn args "out") with |_-> "") in
    let params_sort_by_col=(try url_decode (List.Assoc.find_exn args "sort_by_col") with |_-> "") in

    let attempt ~f a =
      try f()
      with Of_sexp_error (exn,t)-> (
          let e = Exn.to_string exn in
          printf "\n<p>syntax error in %s: %s when parsing the substring \"%s\"</p>\n" a e (Sexp.to_string t);
          raise exn
        )
    in

    (* eg.: input_cols_sexp="(((machine_name(xrtuk-08-02 xrtuk-08-04))(active_session_count(1)))((machine_name(xrtuk-08-02 xrtuk-08-04)))((machine_name(xrtuk-08-02 xrtuk-08-04))(active_session_count(2 3)))((machine_name(xrtuk-08-02 xrtuk-08-04))(active_session_count(1 2 3))(soms(288))))" *)
    let input_cols =
      if params_cols <> "" then
        attempt ~f:(fun ()->cols_t_of_sexp (Sexp.of_string params_cols) ) "cols"
      else (*default value *) 
        []
    in 
    printf "<input_cols_sexp %s/>\n" (Sexp.to_string (sexp_of_cols_t input_cols));

    let input_rows = 
      if params_rows <> "" then
        attempt ~f:(fun ()->rows_t_of_sexp (Sexp.of_string params_rows)) "rows"
      else (*default value *)
        []
    in
    printf "<input_rows_sexp %s/>\n" (Sexp.to_string (sexp_of_rows_t input_rows));


    (* base context is used to fill any context gap not expressed in row and column contexts
       eg. [("build_number",[44543;55432]);("job_id",[1000;4000]);("number_of_cpus",[1]);...]
       -- append (OR) the results of each element in the list
      TODO: is base context restrictive or conjuntive, ie does it restrict possible contexts in 
            the cells or does it contribute to them with lower-priority than rows and col contexts?
      TODO: use intersection between base_context and input_cols and input_rows
     *)
    let input_base_context = 
      if params_base <> "" then
        attempt ~f:(fun ()->base_t_of_sexp (Sexp.of_string params_base)) "base" 
      else (*default value *)
        []
    in
    printf "<input_base_sexp %s/>\n" (Sexp.to_string (sexp_of_base_t input_base_context));

    let baseline_col_idx =
       if params_baseline <> "" then
         attempt ~f:(fun ()->baseline_t_of_sexp (Sexp.of_string params_baseline)) "baseline"
       else (*default value *)
         0
    in
    printf "<input_baseline_col_sexp %s/>\n" (Sexp.to_string (sexp_of_baseline_t baseline_col_idx));

    let out =
       if params_out <> "" then
         attempt ~f:(fun ()->out_t_of_sexp (Sexp.of_string (String.capitalize params_out))) "out"
       else (*default value *)
         `Html 
    in
    printf "<input_out_sexp \"%s\" %s/>\n" (params_out) (Sexp.to_string (sexp_of_out_t out));

    let sort_by_col =
       if params_sort_by_col <> "" then
         Some (attempt ~f:(fun ()->sort_by_col_t_of_sexp (Sexp.of_string (String.capitalize params_sort_by_col))) "sort_by_col")
       else (*default value *)
         None
    in

    (* === process === *)

    progress "<p>Progress...:";

    let soms_of_tc tc_fqn =
      let query = sprintf "select som_id from soms where tc_fqn='%s'" tc_fqn in
      Array.to_list (Array.map (Sql.exec_exn ~conn ~query)#get_all ~f:(fun x->x.(0)))
    in
    let rec_of_som som_id =
      let query = sprintf "select som_name,tc_fqn,more_is_better,units,positive from soms where som_id='%s'" som_id in
      (Sql.exec_exn ~conn ~query)#get_all.(0)
    in
    let name_of_som som_id = (rec_of_som som_id).(0) in
    let tc_of_som som_id   = (rec_of_som som_id).(1) in
    let more_is_better_of_som som_id = (rec_of_som som_id).(2) in
    let unit_of_som som_id = (rec_of_som som_id).(3) in
    let has_table table_name =
      let query = sprintf "select table_name from information_schema.tables where table_schema='public' and table_name='%s'" table_name in
      (Array.to_list (Sql.exec_exn ~conn ~query)#get_all) <> []
    in
    let columns_of_table table_name =
      let query = sprintf "select column_name from information_schema.columns where table_name='%s'" table_name in
      Array.to_list (Array.map (Sql.exec_exn ~conn ~query)#get_all ~f:(fun x->x.(0)))
    in
    let contexts_of_som_id som_id =
      (List.filter
        (columns_of_table (sprintf "som_config_%s" som_id))
        ~f:(fun e->e<>"som_config_id")
      )
    in
    let contexts_of_tc_fqn tc_fqn =
      (List.filter
        (columns_of_table (sprintf "tc_config_%s" tc_fqn))
        ~f:(fun e->e<>"tc_config_id")
      )
    in
    let contexts_of_tc =
      (List.filter
        (columns_of_table "tc_config")
        ~f:(fun e->not (List.mem e ~set:["tc_fqn";"tc_config_id";"machine_id"]))
      )
    in
    (*
    let all_contexts_of_tc tc_fqn =
      let tc_contexts = 
        (List.filter
          (columns_of_table "tc_config")
          ~f:(fun e->not (List.mem e ["tc_fqn";"tc_config_id";"machine_id"]))
        )@
        (List.filter
          (columns_of_table (sprintf "tc_config_%d" tc_fqn))
          ~f:(fun e->e<>"tc_config_id")
        )
      in
      List.map
        (List.map (soms_of_tc tc_id) ~f:contexts_of_som)
        ~f:(fun som_contexts->tc_contexts @ som_contexts)
    in
    *)
    let contexts_of_machine = List.filter (columns_of_table "machines") ~f:(fun e->e<>"machine_id") in
    let contexts_of_build = List.filter (columns_of_table "builds") ~f:(fun e->e<>"build_id") in
    let values_of cs ~at:cs_f = List.filter cs ~f:(fun (k,v)->List.mem k ~set:cs_f) in

(*
    let latest_build_of_branch branch =
      let query = sprintf "select max(build_number) from builds where branch='%s'" branch in
      (Sql.exec_exn ~conn ~query)#get_all.(0).(0)
    in
*)
    let builds_of_branch branch =
      let query = sprintf "select build_number from builds where branch='%s' order by build_number desc" branch in
      List.map (Array.to_list ((Sql.exec_exn ~conn ~query)#get_all)) ~f:(fun x->x.(0))
    in

    (*TODO: touch each element of the context when it is used; if an element is not used at the end of this function,
            then raise an error indicating that probably there's a typo in the context element
     *) 
    let measurements_of_cell context = 
       let get e ctx = match List.find_exn ctx ~f:(fun (k,v)->e=k) with |k,v->v in
       let measurements_of_som som_id =
         let has_table_som_id som_id = has_table (sprintf "som_config_%s" som_id) in
         let tc_fqn = tc_of_som som_id in 
         let query = "select measurements.result from measurements "
           ^(sprintf "join tc_config_%s on measurements.tc_config_id=tc_config_%s.tc_config_id " tc_fqn tc_fqn)
           ^(if has_table_som_id som_id then
              (sprintf "join som_config_%s on measurements.som_config_id=som_config_%s.som_config_id " som_id som_id)
             else ""
            )
           ^"join tc_config on measurements.job_id=tc_config.job_id "
           ^"join machines on tc_config.machine_id=machines.machine_id "
           ^"join jobs on tc_config.job_id=jobs.job_id "
           ^"join builds on jobs.build_id=builds.build_id "
           ^"where "
           ^(sprintf "measurements.som_id=%s " som_id)
           ^(List.fold_left (values_of context ~at:contexts_of_machine) ~init:"" ~f:(fun acc (k,vs)->
              match vs with []->""|_->
              sprintf "%s and (%s) " acc
              (List.fold_left vs ~init:"" ~f:(fun acc2 v->
                sprintf "%s%smachines.%s='%s' " acc2 (match acc2 with |""->""|_->"or ") k v
              ))
            ))
           ^(if has_table_som_id som_id then
             (List.fold_left (values_of context ~at:(contexts_of_som_id som_id)) ~init:"" ~f:(fun acc (k,vs)->
              match vs with []->""|_->
              sprintf "%s and (%s) " acc 
              (List.fold_left vs ~init:"" ~f:(fun acc2 v->
                sprintf "%s%ssom_config_%s.%s='%s' " acc2 (match acc2 with |""->""|_->"or ") som_id k v
              ))
            ))
             else ""
            )
           ^(List.fold_left (values_of context ~at:(contexts_of_tc_fqn tc_fqn)) ~init:"" ~f:(fun acc (k,vs)->
              match vs with []->""|_->
              sprintf "%s and (%s) " acc
              (List.fold_left vs ~init:"" ~f:(fun acc2 v->
                sprintf "%s%stc_config_%s.%s='%s' " acc2 (match acc2 with |""->""|_->"or ") tc_fqn k v
              ))
            ))
           ^(List.fold_left (values_of context ~at:(contexts_of_tc)) ~init:"" ~f:(fun acc (k,vs)->
              match vs with []->""|_->
              sprintf "%s and (%s) " acc
              (List.fold_left vs ~init:"" ~f:(fun acc2 v->
                sprintf "%s%stc_config.%s='%s' " acc2 (match acc2 with |""->""|_->"or ") k v
              ))
            ))
           ^(List.fold_left (values_of context ~at:(contexts_of_build)) ~init:"" ~f:(fun acc (k,vs)->
              match vs with []->""|_->
              sprintf "%s and (%s) " acc
              (List.fold_left vs ~init:"" ~f:(fun acc2 v->
                sprintf "%s%sbuilds.%s='%s' " acc2 (match acc2 with |""->""|_->"or ") k v
              ))
            ))
          in
          Array.to_list (Array.map (Sql.exec_exn ~conn ~query)#get_all ~f:(fun x->x.(0)))
        in
        (* add measurements for each one of the soms in the cell *)
        List.concat (List.map ~f:measurements_of_som (get "soms" context))
    in

    let context_of base row col =
      (* we use intersection to obtain the result when the same context is present in more than one input source *)
      List.fold_left (base @ row @ col) ~init:[] ~f:(fun acc (ck,cv)->
        let x,ys = List.partition ~f:(fun (k,v)->k=ck) acc in
        match x with
          |(k,v)::[]->(* context already in acc, intersect the values *)
            if k<>ck then (failwith (sprintf "k=%s <> ck=%s" k ck));
            (k, List.filter cv ~f:(fun x->List.mem x ~set:v))::ys
          |[]->(* context not in acc, just add it *)
            (ck,cv)::ys
          |x->(* error *)
            failwith (sprintf "More than one element with the same context")
      )
    in
    let expand_latest_build_of_branch c_kvs =
      let k_branch = "branch" in
      let k_build_number = "build_number" in
      let v_latest_in_branch = "latest_in_branch" in
      let _,branches=List.find_exn ~f:(fun (k,vs)->k=k_branch) c_kvs in
      (* list of all builds in all branches *)
      let builds_of_branches =
        List.slice
          (builds_of_branch (List.nth_exn branches 0) (*TODO: handle >1 branch in context*))
          0 5 (* take up to 5 elements in the list *)
      in
      debug (sprintf "builds_of_branches=%s" (List.fold_left ~init:"" builds_of_branches ~f:(fun acc b->acc ^","^b)));

      let has_latest_in_branch_value =
        List.exists c_kvs ~f:(fun (k,vs) -> if k<>k_build_number then false else List.exists vs ~f:(fun v->v=v_latest_in_branch))
      in
      (* if 'latest_in_branch' value is present, expand ctx into many ctxs, one for each build; otherwise, return the ctx intact *)
      if not has_latest_in_branch_value then [c_kvs]
      else List.map builds_of_branches ~f:(fun builds->
        List.map c_kvs ~f:(fun (k,vs) ->
          if k<>k_build_number then (k,vs)
          else k,(List.map vs ~f:(fun v->
            if v<>v_latest_in_branch then v else builds
          ))
        )
      )
    in
    let expand ctx = (*expand cell context into all possible context after expanding ctx templates into values*)
      (* 1. value template: latest_in_branch *)
      expand_latest_build_of_branch ctx
      (* ... potentially other expansions in the future... *)
    in
    let b = input_base_context in
    let cs = input_cols in
    let rs = List.fold_left ~init:[] input_rows (* expand tcs into soms *) (*todo: this should also apply to columns *)
      ~f:(fun acc r-> let r_expanded = List.concat (List.map r 
          ~f:(fun (k,v)->match k with 
            | _ when k="tcs" -> List.concat (List.map v ~f:(fun tc->List.map (soms_of_tc tc) ~f:(fun som->("soms",[som]))))
            | _ -> (k,v)::[] 
          ))
        in
        let soms,no_soms = List.partition r_expanded ~f:(fun (k,v)->k="soms") in
        let soms = List.sort soms ~cmp:(fun (xk,xv) (yk,yv)->(int_of_string(List.hd_exn xv)) - (int_of_string(List.hd_exn yv))) in
        acc @ (List.map soms ~f:(fun som->[som] @ no_soms))
      )
    in
    progress (sprintf "table: %d lines: " (List.length rs));
    let ctx_and_measurements_of_1st_cell_with_data expand_f ctx =
      let ctxs = expand_f ctx in
      let measurements_of_cells = List.map ctxs ~f:(fun c->c, measurements_of_cell c) in
      let first = List.find measurements_of_cells ~f:(fun (c,ms)->ms<>[]) in
      match first with None->ctx,[]|Some (c,ms)->c,ms
    in
    let measurements_of_table = 
      List.mapi rs ~f:(fun i r->
        progress (sprintf "%d..." i);
        r, (List.map cs ~f:(fun c->
          let ctx, ms = ctx_and_measurements_of_1st_cell_with_data expand (context_of b r c) in
          (r, c, ctx,  ms)
        ))
      )
    in

    (* === output === *)

    let n_sum xs = List.fold_left ~init:(0,0.) ~f:(fun (n,sum1) x->succ n, sum1 +. (float_of_string x)) xs in
    let avg xs = let n,sum=n_sum xs in sum /. (float n) in
    let variance xs = (* 2-pass algorithm *)
      let n,sum1 = n_sum xs in
      if n<2
      then 0.0 (* default variance if not enough measurements present to compute it *)
      else
        let mean = sum1 /. (float n) in
        let sum2 = List.fold_left ~init:0. ~f:(fun sum2 x->sum2 +. ((float_of_string x) -. mean)*.((float_of_string x) -. mean)) xs in
        sum2 /. (float (n-1))
    in
    let stddev xs = sqrt (variance xs) in
    let is_valid f = match classify_float f with |FP_infinite|FP_nan->false |_->true in
    let relative_std_error xs =
      let avg = avg xs in let stddev = stddev xs in
      if (is_valid avg) && (is_valid stddev) then
        int_of_float (stddev /. avg *. 100.)
      else 0
    in
    ignore (relative_std_error []);

    (* round value f to the optimal decimal place according to magnitude of its stddev *)
    let round f stddev =
      if abs_float (stddev /. f) < 0.00000001 (* stddev = 0.0 doesn't work because of rounding errors in the float representation *)
      then (sprintf "%f" f), f
      else
      (* 0. compute magnitude of stddev relative to f *)
      let f_abs = abs_float f in
      let magnitude = (log stddev) /. (log 10.0) in
      let newdotpos = (if is_valid magnitude then int_of_float (if magnitude < 0.0 then floor (magnitude) else (floor magnitude) +. 1.0) else 1) in
      let f_str = sprintf "%f" f_abs in
      let dotpos = (String.index_exn f_str '.') in
      let cutpos = (dotpos - newdotpos) in
      if cutpos < 0
      then ("0",0.0) (* stddev magnitude is larger then value f *)
      else 
        (* 1. round for the computed magnitude of stddev *)
        let dig_from s pos = (String.sub s ~pos:(pos+1) ~len:1) in
        let dig=dig_from f_str cutpos in
        let rounddigit,roundpos = (* round last significant value using the next digit value *) 
          if dig="."
            then (int_of_string (dig_from f_str (cutpos+1)),newdotpos-1)
            else (int_of_string dig,if newdotpos<0 then newdotpos else newdotpos-1)
        in
        let f_rounded = if rounddigit < 5 then f_abs else f_abs +. 10.0 ** (float_of_int roundpos) in
        (* 2. print only significant digits *)
        let f_result = (
         let f_str_rounded = sprintf "%f" f_rounded in
         let f_abs_str_rounded = (if (f_rounded<1.0) 
          then (* print the rounded value up to its last significant digit *)
            String.sub f_str_rounded ~pos:0 ~len:(cutpos+1)
          else (* print the rounded value up to its last significant digit and fill the rest with 0s *)
            let dotposr = String.index_exn f_str_rounded '.' in
            sprintf "%s%s" 
              (String.sub f_str_rounded ~pos:0 ~len:(cutpos+1)) 
              (if dotposr-(cutpos+1)>0 then (String.make (dotposr-(cutpos+1)) '0') else "")
          ) in
          (sprintf "%s%s" (if f<0.0 then if f_abs_str_rounded <> "0" then "-" else "" else "") f_abs_str_rounded)
        )
        in
        (
         (*sprintf "f_str=%s stddev=%f magnitude=%f cutpos=%d dotpos=%d newdotpos=%d dig=%s rounddigit=%d roundpos=%d f_rounded=%f f=%f %s" f_str stddev magnitude cutpos dotpos newdotpos dig rounddigit roundpos f_rounded f*)
          f_result, float_of_string f_result
        )

    in
    let of_round avg stddev ~f0 ~f1 ~f2 =
      let lower = avg -. 2.0 *. stddev in (* 2-sigma = 95% confidence assuming normal distribution *)
      let upper = avg +. 2.0 *. stddev in
      if (abs_float avg) < min_float
      then f0 ()
      else if stddev /. avg < 0.05 (* see if the relative std error is <5% *)
        then f1 (round avg stddev)                                           (* 95% confidence *)
        else f2 (round lower stddev) (round avg stddev) (round upper stddev) (* 95% confidence *)
    in
    (* pretty print a value f and its stddev *)
    let str_of_round ?f1_fmt ?f2_fmt avg stddev =
      let _f1_fmt = match f1_fmt with None->"%s"|Some x->x in
      let _f2_fmt = match f2_fmt with None->"[%s, %s, %s]"|Some x->x in
      of_round avg stddev
        ~f0:(fun ()->"0")
        ~f1:(fun a->sprintf (Scanf.format_from_string _f1_fmt "%s") (fst a) ) 
        ~f2:(fun l a u->sprintf (Scanf.format_from_string _f2_fmt "%s %s %s") (fst l) (fst a) (fst u))
    in
    let val_of_round avg stddev =
      of_round avg stddev
        ~f0:(fun ()->Avg 0.0)
        ~f1:(fun a->Avg (snd a))
        ~f2:(fun l a u->Range ((snd l),(snd a),(snd u)) )
    in
    let is_green baseline value more_is_better =
      if more_is_better then
        match baseline, value with
        |Avg b, Avg v-> (v>=b)
        |Avg b, Range (vl, va, vu)-> (va>=b)
        |Range (bl, ba, bu), Avg v-> (v>=ba)
        |Range (bl, ba, bu), Range (vl,va,vu)-> (va>=ba)
     else (* less is better *)
        match baseline, value with
        |Avg b, Avg v-> (v<=b)
        |Avg b, Range (vl, va, vu)-> (va<=b)
        |Range (bl, ba, bu), Avg v-> (v<=ba)
        |Range (bl, ba, bu), Range (vl,va,vu)-> (va<=ba)
    in
    let delta baseline value more_is_better =
      match baseline, value with
        |Avg b, Avg v-> v -. b
        |Avg b, Range (vl, va, vu)-> va -. b
        |Range (bl, ba, bu), Avg v-> v -. ba
        |Range (bl, ba, bu), Range (vl,va,vu)-> va -. ba
    in
    let proportion baseline value more_is_better =
      (delta baseline value more_is_better) /.
      (match baseline with
      |Avg b-> abs_float b
      |Range (bl, ba, bu)-> abs_float ba)
    in
    (* pretty print a list of values as average and stddev *) 
    let str_stddev_of ?f1_fmt ?f2_fmt xs =
      try
        if List.length xs < 1 then "-"
        else str_of_round ?f1_fmt ?f2_fmt (avg xs) (stddev xs)
      with |e-> sprintf "error %s: %s %f %f " (Exn.to_string e) (Sexp.to_string (sexp_of_str_lst_t xs)) (avg xs) (stddev xs)
    in
    let val_stddev_of xs =
      try
        if List.length xs < 1 then Avg 0.0
        else val_of_round (avg xs) (stddev xs)
      with |_-> Avg (-1000.0)
    in

    let sort_table mt = (* use url option sort_by_col if present *)
      match sort_by_col with
      |None->mt
      |Some compare_col_idx->
        let mt_xs, mt_0s = List.partition mt
          ~f:(fun (r,cs)->
            let _,_,_,cmp_ms=List.nth_exn cs compare_col_idx in
            let _,_,_,base_ms=List.nth_exn cs baseline_col_idx in
            (List.length cmp_ms > 0) && (List.length base_ms > 0)
          )
        in
        List.sort (mt_xs)  (* rows with at least one measurement *)
          ~cmp:(fun (r1,cs1) (r2,cs2) ->
          let ms cs =
            let _,_,_,cmp_ms = List.nth_exn cs compare_col_idx in
            let _,_,_,base_ms = List.nth_exn cs baseline_col_idx in
            proportion (val_stddev_of base_ms) (val_stddev_of cmp_ms) None
          in
          let ms1, ms2 = (abs_float (ms cs1)),(abs_float (ms cs2)) in
          if ms1 > ms2 then -1 else if ms2 > ms1 then 1 else 0 (* decreasing order *)
        ) @ mt_0s (* rows with no measurements stay at the end *)
    in

    (* compute link to rage graph *)
    (* 1. show v_* values for the union of base+row+(each column) *)
    (* 2. ???split by (f_* ) any keys on the columns *)
    (* eg.: http://perf/?som=41&xaxis=numvms&show_dist=on&f_branch=1&v_build_tag=&v_dom0_memory_static_max=752&v_dom0_memory_target=(NULL)&v_cc_restrictions=f&v_memsize=256&v_vmtype=dom0 *)
    let link_ctx_of_row ctxs =
      List.fold_left ctxs ~init:[] ~f:(fun acc (ck,cv)->
        let x,ys = List.partition ~f:(fun (k,v)->k=ck) acc in
        match x with
          |(k,v)::[]->(* context already in acc, union the values *)
            if k<>ck then (failwith (sprintf "link: k=%s <> ck=%s" k ck));
            (k, List.dedup (cv @ v))::ys
          |[]->(* context not in acc, just add it *)
            (ck,cv)::ys
          |x->(* error *)
            failwith (sprintf "link: More than one element with the same context")
      )
    in
    let link_ctxs = (List.map (sort_table measurements_of_table) ~f:(fun (r,cs)->link_ctx_of_row (List.concat (List.map cs ~f:(fun (_,_,ctx,_)->ctx))))) in
    let link_xaxis = List.dedup (List.concat (List.map cs ~f:(fun c-> List.map c ~f:(fun (x,_)->x)))) in

    (* writers *)

    let rage_encode url =
      List.fold_left
         [
           (" ","+");   (* escape http params according to what rage expects *)
         ]
         ~init:url
        ~f:(fun acc (f,t)->(Str.global_replace (Str.regexp f) t acc)) (* f->t *)
    in

    let html_writer table =

      let str_of_values vs=List.fold_left vs ~init:"" ~f:(fun acc v->if acc="" then "\""^v^"\"" else acc^", \""^v^"\"") in
      let str_of_ctxs ?(txtonly=false) kvs = 
        List.fold_left kvs ~init:"" ~f:(fun acc (k,v)->
          (sprintf "%s %s=(%s)%s\n" acc k (str_of_values v) (if txtonly then "" else "<br>") )
        )
      in
      let str_desc_of_ctxs kvs =
        List.fold_left kvs ~init:"" ~f:(fun acc (k,vs)->
          if k<>"soms" then acc else
          (sprintf "%s %s<br>\n" acc (List.fold_left vs ~init:"" ~f:(fun acc2 som->
              let s=sprintf "%s: <b>%s</b> (%s%s)" (tc_of_som som) (name_of_som som) (let u=unit_of_som som in if u="" then u else u^", ") (sprintf "%s is better" (let mb=more_is_better_of_som som in if mb="" then "none" else if mb="f" then "less" else "more"))  in
              if acc="" then s else acc^","^s
            ))
          )
        )
      in
          let link ctx =
          (* link *)
          (
          (* rage is not generic enough to receive an arbirary number of soms in a link, pick just the first one *)
          let som_id=match List.find_exn ctx ~f:(fun (k,_)->k="soms") with |(k,v)->List.hd_exn v in
          (sprintf "<a href='http://perf/?som=%s&show_dist=on%s%s'>graph</a>" som_id
            (* xaxis *)
            (List.fold_left link_xaxis ~init:"" ~f:(fun acc x->sprintf "%s%s" acc (sprintf "&xaxis=%s" x)))
            (* preset values *)
            (List.fold_left ctx ~init:"" ~f:(fun acc (k,vs)->sprintf "%s%s" acc 
             (List.fold_left vs ~init:"" ~f:(fun acc2 v->sprintf "%s&v_%s=%s" acc2 k (rage_encode v))
             )
            ))
          ))
          in
      let is_more_is_better ctx =
        match List.find ctx ~f:(fun (k,_)->k="soms") with
        |None->None
        |Some (k,_vs)->(
          let rec is_mb acc vs = (match vs with
          |[]->if acc=None then None else acc
          |v::vs->(let mb = more_is_better_of_som v in
            if mb="" then is_mb acc vs (* ignore more_is_better if not defined in db *)
            else
              let mbtf = match mb with m when m="f"->false|_->true in
              match acc with
              |None->is_mb (Some mbtf) vs
              |Some _mbtf->if _mbtf=mbtf
              then is_mb (Some mbtf) vs  (* more_is_better values agree between soms *)
              else None                  (* more_is_better values disagree between soms *)
            )
          ) in
          is_mb None _vs
        )
      in
      let html_table =
      sprintf "<tr> <td style='background-color:papayawhip;'>%s</td></tr>\n%s%s%s"
      (* print the base context *)
      (str_of_ctxs b)
      (* print the header *)
      (sprintf "<tr> <td><b>id</b></td> <td><b>Description</b></td> <td><b>View</b></td> %s </tr>"
        (List.foldi cs ~init:"" ~f:(fun i acc _ ->
          sprintf "%s <td><b>%s</b></td>" acc (if i=baseline_col_idx then "Baseline" else (sprintf "Comparison %d" i))
        ))
      )
      (* print the columns *)
      (sprintf "<tr><td></td><td></td><td></td>%s</tr>"
        (List.fold_left ~init:""
          ~f:(fun acc cs->sprintf "%s <td style='background-color:tan;'> %s </td>" acc (str_of_ctxs cs)) cs
        )
      )
      (* print the cells *)
      (List.fold_left ~init:"" ~f:(fun acc r_ms->acc^r_ms)
       (List.map2_exn table link_ctxs ~f:(fun (r,cs) lnkctx ->
        sprintf "<tr> <td style='background-color:skyblue; max-width:200px;'>%s</td> <td style='max-width:200px;'>%s</td> <td>%s</td> %s </tr>\n\n" 
          (* row id/title *)
          (str_of_ctxs r)
          (* row description *)
          (str_desc_of_ctxs r)
          (* graph link *)
          (link lnkctx)
          (* cells to the right *)
          (List.fold_left ~init:"" ~f:(fun acc c_ms->(sprintf "%s <td style='text-align:center;'> %s </td>\n" acc c_ms))
            (List.mapi cs ~f:(fun i (r,c,ctx,ms)->
              let _,_,_,baseline_ms = List.nth_exn cs baseline_col_idx in
              sprintf "<div onmouseover=\"this.style.backgroundColor='#FC6'\" onmouseout=\"this.style.backgroundColor='white'\" debug_r='%s' debug_c='%s' title='context:\n%s' debug_ms='%s'>%s</div>"
              (Sexp.to_string (sexp_of_ctx_t r))
              (Sexp.to_string (sexp_of_ctx_t c))
              (str_of_ctxs ctx ~txtonly:true)
              (Sexp.to_string (sexp_of_str_lst_t ms))
              (sprintf "<span style='color:%s'>%s <br> %s %s</span>"
                (if baseline_col_idx = i then "" else
                 match is_more_is_better ctx with
                 |None->""
                 |Some mb->if is_green (val_stddev_of baseline_ms) (val_stddev_of ms) mb then "green" else "red"
                )
                (str_stddev_of ms)
                (sprintf "<sub>(%d)</sub>" (List.length ms))
                (if baseline_col_idx = i then "" else
                 match is_more_is_better ctx with
                 |None->""
                 |Some mb->sprintf "<sub>(%+.0f%%)</sub>" (100.0 *. (proportion (val_stddev_of baseline_ms) (val_stddev_of ms) mb))
                )
              )
            ))
          )
       ))
      )
      in
      printf "%s" "<p>Brief Rage Report</p>\n";
      printf "%s" "<ul><li> Numbers reported at 95% confidence level from the data of existing runs\n";
      printf "%s" "<li> (x) indicates number of samples\n";
      printf "%s" "<li> (x%) indicates difference with baseline column\n";
      printf "%s" "<li> [lower, avg, upper] indicates [avg-2*stddev, avg, avg+2*stddev]. If relative standard error < 5%, only avg is shown.</ul>\n";
      printf "<table>%s</table>" html_table;
    in

    let wiki_writer table =

      let str_of_values vs=List.fold_left vs ~init:"" ~f:(fun acc v->if acc="" then "\""^v^"\"" else acc^", \""^v^"\"") in
      let str_of_ctxs ?(txtonly=false) kvs = 
        List.fold_left kvs ~init:"" ~f:(fun acc (k,v)->
          (sprintf "%s %s=(%s)%s " acc k (str_of_values v) (if txtonly then "" else "\\\\") )
        )
      in
      let str_desc_of_ctxs kvs =
        List.fold_left kvs ~init:"" ~f:(fun acc (k,vs)->
          if k<>"soms" then acc else
          (sprintf "%s %s \\\\" acc (List.fold_left vs ~init:"" ~f:(fun acc2 som->
              let s=sprintf "%s: *%s* (%s%s)" (tc_of_som som) (name_of_som som) (let u=unit_of_som som in if u="" then u else u^", ") (sprintf "%s is better" (let mb=more_is_better_of_som som in if mb="" then "none" else if mb="f" then "less" else "more"))  in
              if acc="" then s else acc^","^s
            ))
          )
        )
      in
          let link ctx =
          (* link *)
          (
          (* rage is not generic enough to receive an arbirary number of soms in a link, pick just the first one *)
          let som_id=match List.find_exn ctx ~f:(fun (k,_)->k="soms") with |(k,v)->List.hd_exn v in
          (sprintf "[graph|http://perf/?som=%s&show_dist=on%s%s]" som_id
            (* xaxis *)
            (List.fold_left link_xaxis ~init:"" ~f:(fun acc x->sprintf "%s%s" acc (sprintf "&xaxis=%s" x)))
            (* preset values *)
            (List.fold_left ctx ~init:"" ~f:(fun acc (k,vs)->sprintf "%s%s" acc 
             (List.fold_left vs ~init:"" ~f:(fun acc2 v->sprintf "%s&v_%s=%s" acc2 k (rage_encode v))
             )
            ))
          ))
          in
      let is_more_is_better ctx =
        match List.find ctx ~f:(fun (k,_)->k="soms") with
        |None->None
        |Some (k,_vs)->(
          let rec is_mb acc vs = (match vs with
          |[]->if acc=None then None else acc
          |v::vs->(let mb = more_is_better_of_som v in
            if mb="" then is_mb acc vs (* ignore more_is_better if not defined in db *)
            else
              let mbtf = match mb with m when m="f"->false|_->true in
              match acc with
              |None->is_mb (Some mbtf) vs
              |Some _mbtf->if _mbtf=mbtf
              then is_mb (Some mbtf) vs  (* more_is_better values agree between soms *)
              else None                  (* more_is_better values disagree between soms *)
            )
          ) in
          is_mb None _vs
        )
      in
      let wiki_table =
      sprintf "| %s|\n%s%s\n%s"
      (* print the base context *)
      (str_of_ctxs b)
      (* print the header *)
      (sprintf "||id|| Description || View || %s \n"
        (List.foldi cs ~init:"" ~f:(fun i acc _ ->
          sprintf "%s %s ||" acc (if i=baseline_col_idx then "Baseline" else (sprintf "Comparison %d" i))
        ))
      )
      (* print the columns *)
      (sprintf "|| || || || %s"
        (List.fold_left ~init:""
          ~f:(fun acc cs->sprintf "%s %s || " acc (str_of_ctxs cs)) cs
        )
      )
      (* print the cells *)
      (List.fold_left ~init:"" ~f:(fun acc r_ms->acc^r_ms)
       (List.map2_exn table link_ctxs ~f:(fun (r,cs) lnkctx ->
        sprintf "| %s | %s | %s | %s \n" 
          (* row id/title *)
          (str_of_ctxs r)
          (* row description *)
          (str_desc_of_ctxs r)
          (* graph link *)
          (link lnkctx)
          (* cells to the right *)
          (List.fold_left ~init:"" ~f:(fun acc c_ms->(sprintf "%s %s | " acc c_ms))
            (List.mapi cs ~f:(fun i (r,c,ctx,ms)->
              let _,_,_,baseline_ms = List.nth_exn cs baseline_col_idx in
(*
              sprintf "<div onmouseover=\"this.style.backgroundColor='#FC6'\" onmouseout=\"this.style.backgroundColor='white'\" debug_r='%s' debug_c='%s' title='context:\n%s' debug_ms='%s'>%s</div>"
              (Sexp.to_string (sexp_of_ctx_t r))
              (Sexp.to_string (sexp_of_ctx_t c))
              (str_of_ctxs ctx ~txtonly:true)
              (Sexp.to_string (sexp_of_str_lst_t ms))
*)
              (sprintf "{color:%s} %s %s %s {color}"
                (if baseline_col_idx = i then "" else
                 match is_more_is_better ctx with
                 |None->""
                 |Some mb->if is_green (val_stddev_of baseline_ms) (val_stddev_of ms) mb then "green" else "red"
                )
                (str_stddev_of ms ~f2_fmt:"\\\\[%s, %s, %s\\\\]")
                (sprintf "~(%d)~" (List.length ms))
                (if baseline_col_idx = i then "" else
                 match is_more_is_better ctx with
                 |None->""
                 |Some mb->sprintf "~(%+.0f%%)~" (100.0 *. (proportion (val_stddev_of baseline_ms) (val_stddev_of ms) mb))
                )
              )
            ))
          )
       ))
      )
      in
      printf "%s" "<pre>";
      printf "%s" "h1. Brief Rage Report\n\n";
      printf "- [live html version, with parameters %s |http://perf/?%s]\n" (List.fold_left params ~init:"" ~f:(fun acc (k,v)->if k="out" then acc else if acc="" then (sprintf "%s=%s" k v) else (sprintf "%s, %s=%s" acc k (url_decode v)))) (List.fold_left params ~init:"" ~f:(fun acc (k,v)->if k="out" then acc else sprintf "%s&%s=%s" acc k (url_decode v)));
      printf "%s" "- Numbers reported at 95% confidence level from the data of existing runs\n";
      printf "%s" "- \\(x) indicates number of samples\n";
      printf "%s" "- \\(x%) indicates difference with baseline column\n";
      printf "%s" "- \\[lower, avg, upper] indicates \\[avg-2*stddev, avg, avg+2*stddev]. If relative standard error < 5%, only avg is shown.\n\n";
      printf "%s" wiki_table;
      printf "%s" "</pre>";
    in

    match out with
    |`Html -> html_writer (sort_table measurements_of_table)
    |`Wiki -> wiki_writer (sort_table measurements_of_table)

end