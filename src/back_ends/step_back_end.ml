open Core_kernel
open Hardcaml
open Buffet_kernel

module Expression = struct
  include Dynamic_expression.Make(Bits)(struct
    type t = Bits.t ref [@@deriving sexp_of, equal]

    let width t = Bits.width !t
  end)

  let evaluate t = evaluate ~deref:(!) t

  let pp ppf a =
    let w = width a in
    Stdio.Out_channel.fprintf ppf "%d'u%d" w (Bits.to_int (evaluate a))
  ;;
end

module Step_monad = Digital_components.Step_monad

include Instructions.Make(Expression)
include Ref(struct
    type t = Bits.t ref

    let get_ref (t : t) = Expression.reference t
  end)
include Control_flow()
include Join()
include Debugging_stdout()

module Executor = struct
  module Component = Digital_components.Component

  module Refs_to_update = struct
    type ref_and_value =
      { ref : Bits.t ref
      ; value : Bits.t
      }
    [@@deriving sexp_of]

    type t = ref_and_value list [@@deriving sexp_of]

    let equal a b =
      List.equal
      (fun a b ->
        phys_equal a.ref b.ref
        && Bits.equal a.value b.value) a b
    ;;

    let undefined = []
  end

  module Empty = struct
    type t = unit [@@deriving sexp_of, equal]

    let undefined = ()
  end

  let component_of_step step =
    Step_monad.create_component
      ~created_at:[%here]
      ~start:(fun () ->
          let%bind.Step_monad result = step in
          Step_monad.return { Step_monad.Component_finished. output = [] ; result }
        )
      ~input:(module Empty)
      ~output:(module Refs_to_update)
  ;;

  let execute step =
    let component, result_event = component_of_step step in
    Component.run_until_finished
      component
      ~first_input:()
      ~next_input:(fun (refs_to_update : Refs_to_update.t) ->
          List.iter refs_to_update ~f:(fun { ref; value } ->
              ref := value);
          if Option.is_some (Step_monad.Event.value result_event) then
            Component.Next_input.Finished
          else
            Component.Next_input.Input ());
    match Step_monad.Event.value result_event with
    | None -> assert false
    | Some x -> x.result
  ;;

  let rec map_items ~f = function
    | [] -> Step_monad.return []
    | hd :: tl ->
      let%bind.Step_monad hd = f hd in
      let%bind.Step_monad tl = map_items ~f tl in
      Step_monad.return (hd :: tl)
  ;;

  let rec program_to_step : 'a . 'a t -> ('a, unit, Refs_to_update.t) Step_monad.t =
    fun program ->
    match program with
    | Return a -> Step_monad.return a
    | Then (ins, k) ->
      begin match ins with
        | New_ref expression ->
          let new_var = ref (Expression.evaluate expression) in
          let%bind.Step_monad _output_ignored = Step_monad.next_step [%here] [] in
          program_to_step (k new_var)

        | Set_ref (var, value) ->
          let value = Expression.evaluate value in
          let%bind.Step_monad () =
            Step_monad.next_step [%here]
              [ { Refs_to_update. ref = var; value; } ]
          in
          var := value;
          program_to_step (k ())

        | While { cond; body } ->
          let rec loop () =
            let cond = Expression.evaluate cond in
            if Bits.is_vdd cond then
              let%bind.Step_monad () = program_to_step body in
              loop ()
            else
              program_to_step (k ())
          in
          loop ()

        | If { cond; then_; else_ } ->
          let cond = Expression.evaluate cond in
          assert (Bits.width cond = 1);
          let%bind.Step_monad ret =
            if Bits.is_vdd cond then
              program_to_step then_
            else
              program_to_step else_
          in
          program_to_step (k ret)

        | Pass ->
          let%bind.Step_monad () = Step_monad.next_step [%here] [] in
          program_to_step (k ())

        | Join progs ->
          let%bind.Step_monad tasks =
            map_items progs ~f:(fun prog ->
                Step_monad.spawn [%here]
                  ~start:(fun () ->
                      let%bind.Step_monad result = program_to_step prog in
                      Step_monad.return { Step_monad.Component_finished. output = [] ; result }
                    )
                  ~input:(module Empty)
                  ~output:(module Refs_to_update)
                  ~child_input:(fun ~parent:() -> ())
                  ~include_child_output:(fun ~parent ~child -> parent @ child))
          in
          let%bind.Step_monad results =
            map_items tasks ~f:(fun task ->
                let rec loop () =
                  match Step_monad.Event.value task with
                  | None -> 
                    let%bind.Step_monad () = Step_monad.next_step [%here] [] in
                    loop ()
                  | Some (a : _ Step_monad.Component_finished.t) -> Step_monad.return a.result
                in
                loop ())
          in
          program_to_step (k results)

        | _ -> raise_s [%message "Incomplete implementation, this should not have happened!"]
      end
  ;;
end

let run program = Executor.(execute (program_to_step program))
