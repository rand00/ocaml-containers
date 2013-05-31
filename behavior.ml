(*
Copyright (c) 2013, Simon Cruanes
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice, this
list of conditions and the following disclaimer.  Redistributions in binary
form must reproduce the above copyright notice, this list of conditions and the
following disclaimer in the documentation and/or other materials provided with
the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*)

(** {1 Behavior Trees for React} *)

(** {2 Behavior tree} *)

type tree =
  | Test of bool React.event                (* test the next occurrence *)
  | TestS of bool React.signal              (* test the current value *)
  | Wait of unit React.event                (* wait for the event to trigger *)
  | Timeout of float                        (* fails after the given timeout *)
  | Do of (unit -> bool)                    (* perform an action *)
  | If of bool React.signal * tree * tree   (* switch *)
  | Sequence of bool * tree list            (* yield to subtrees sequentially. bool: loop? *)
  | Select of select_strategy * tree list   (* select one subtree *)
  | Parallel of parallel_strategy * tree list   (* run all subtrees in parallel *)
  | Closure of (unit -> tree)               (* build a tree dynamically *)
  | Succeed
  | Fail
  (** A behavior tree *)
and select_strategy = tree list -> (unit -> tree option)
  (** How to select a subtree to run. It yields a subtree until it
      decides to fail *)
and parallel_strategy =
  | PSForall  (** succeeds when all subtrees succeed *)
  | PSExists  (** succeeds when some subtree succeeds *)

let strategy_inorder l =
  let cur = ref l in
  fun () -> match !cur with
    | [] -> None
    | t::l' ->
      cur := l';
      Some t

let strategy_random ?(proba_fail=0.05) l =
  let a = Array.of_list l in
  fun () ->
    if Random.float 1. < proba_fail
      then None
      else (* choose in array *)
        let t = a.(Random.int (Array.length a)) in
        Some t

let mk_succeed = Succeed

let mk_fail = Fail

let mk_test e = Test e

let mk_test_s s = TestS s

let mk_wait e = Wait e

let mk_timeout f = Timeout f

let mk_do act = Do act

let mk_do_ok act = Do (fun () -> act (); true)

let mk_if s then_ else_ = If (s, then_, else_)

let mk_sequence ?(loop=false) l =
  assert (l <> []);
  Sequence (loop, l)

let mk_select ?(strat=strategy_inorder) l =
  assert (l <> []);
  Select (strat, l)

let mk_or_else t1 t2 =
  mk_select ~strat:strategy_inorder [t1; t2]

let mk_parallel ?(strat=PSForall) l =
  assert (l <> []);
  Parallel (strat, l)

let mk_closure f =
  Closure f

(** {2 Lightweight futures} *)

module Fut = struct
  type 'a t = {
    mutable value : 'a option;
    mutable handlers : ('a -> unit) list;
  }

  let create () =
    let fut = {
      value = None;
      handlers = [];
    } in
    let send x = match fut.value with
      | Some _ -> raise (Invalid_argument "Behavior.Fut.create: future already set")
      | None ->
        fut.value <- Some x;
        List.iter (fun f -> f x) fut.handlers
    in
    fut, send

  (* add [h] as a handler that waits for [fut] to complete. May call [h]
      immediately *)
  let subscribe fut h =
    match fut.value with
    | None -> fut.handlers <- h :: fut.handlers
    | Some x -> h x

  let is_set fut = match fut.value with
    | None -> false
    | Some _ -> true

  let return x = {
    value = Some x;
    handlers = [];
  }

  let bind fut f =
    (* result *)
    let result, send = create () in
    subscribe fut (fun x ->
      (* [fut_f] is what [f] returns. When this completes, [result] will
          be updated *)
      let fut_f = f x in
      subscribe fut_f (fun y -> send y));
    result

  let next e =
    let res, send = create () in
    let ev = React.E.map send (React.E.once e) in
    res.handlers <- [fun _ -> ignore ev];  (* keep reference *)
    res

  let wait fut =
    let res, set = React.S.create None in
    subscribe fut (fun x -> set (Some x));
    ignore (React.S.retain res (fun _ -> ignore fut));  (* keep ref *)
    res

  let map f fut =
    let res, send = create () in
    subscribe fut (fun x -> send (f x));
    res

  let first l =
    let res, send = create () in
    (* is any of the values set? *)
    let any_set = ref false in
    (try
      List.iter
        (fun fut -> match fut.value with
          | None -> ()
          | Some x -> any_set := true; send x; raise Exit)
      l
    with Exit -> ());
    (* if no element of [l] is already set, add handlers *)
    (if not !any_set then
      List.iter
        (fun fut -> subscribe fut
          (fun x -> if not !any_set then (any_set := true; send x)))
        l);
    res

  let last l =
    let res, send = create () in
    let count = ref (List.length l) in
    List.iter
      (fun fut -> subscribe fut
        (fun x ->
          decr count;
          if !count = 0 then send x))
      l;
    res

  let filter p l =
    let res, send = create () in
    let any_ok = ref false in  (* any future succeeded? *)
    let count = ref (List.length l) in
    List.iter
      (fun fut -> subscribe fut
        (fun x ->
          if !any_ok
            then ()
          else if p x
            then (any_ok := true; send (Some x))
          else 
            (decr count; if !count = 0 then send None)))
      l;
    res

  (** Get value, which must be present *)
  let unsafe_get fut = match fut.value with
    | None -> assert false
    | Some x -> x

  let l2 f a b =
    let res, send = create () in
    let count = ref 2 in
    let compute () =
      let y = f (unsafe_get a) (unsafe_get b) in
      send y
    in
    subscribe a (fun _ -> decr count; if !count = 0 then compute ());
    subscribe b (fun _ -> decr count; if !count = 0 then compute ());
    res
end

(** {2 Run a tree} *)

type result = bool Fut.t

let run ?delay tree =
  let open React in
  (* run given tree *)
  let rec run tree = 
    match tree with
    | Test e -> Fut.next e
    | TestS s -> Fut.return (S.value s)
    | Wait e -> Fut.next (E.stamp e true)
    | Timeout howlong ->
      begin match delay with
      | None -> failwith "Behavior.run: not delay function provided"
      | Some delay ->
        let timeout = delay howlong in
        Fut.next (E.stamp timeout false)
      end
    | Do act ->
      let b = act () in
      Fut.return b
    | If (s, then_, else_) -> (* depends on value of signal *)
      if S.value s then run then_ else run else_
    | Sequence (loop, l) -> run_sequence ~loop l
    | Select (strat, l) -> run_select ~strat l
    | Parallel (strat, l) -> run_parallel ~strat l
    | Closure f -> let tree' = f () in run tree'
    | Succeed -> Fut.return true
    | Fail -> Fut.return false
  and run_sequence ~loop start =
    let rec process l = match l with
    | [] when loop -> run_sequence ~loop start
    | [] -> Fut.return true  (* success *)
    | t::l' ->
      let res_t = run t in
      Fut.bind res_t
        (fun t_succeeded ->
          if t_succeeded
            then process l'
            else Fut.return false)
    in
    process start
  and run_select ~strat l =
    (* choice function *)
    let choose = strat l in
    (* try a subtree *)
    let rec try_one () =
      match choose () with
      | None -> Fut.return false  (* failure *)
      | Some t ->
        let res_t = run t in
        Fut.bind res_t
          (fun t_succeeded -> if t_succeeded
            then Fut.return true
            else try_one ())
    in
    try_one ()
  and run_parallel ~strat l =
    let results = List.map run l in
    match strat with
    | PSExists ->
      let ok = Fut.filter (fun x -> x) results in
      Fut.map
        (function | None -> false | Some _ -> true)
        ok
    | PSForall ->
      let failed = Fut.filter (fun x -> not x) results in
      Fut.map
        (function | None -> true | Some _ -> false)
        failed
  in
  run tree
