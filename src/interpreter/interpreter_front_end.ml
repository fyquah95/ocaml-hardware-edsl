open Core_kernel
open Ocaml_edsl_kernel
open Hardcaml

module Expression = struct
  open Bits

  type t =
    | Value of Bits.t
    | Reference of Bits.t ref

  let value = function
    | Value a -> a
    | Reference r -> !r

  let zero width = Value (Bits.zero width)
  let one width = Value (Bits.one width)
  let of_int ~width value = Value (Bits.of_int ~width value)

  let (+:) a b = Value ((value a) +: (value b))
  let (+:.) a b = Value ((value a) +:. b)
  let (-:) a b = Value ((value a) -: (value b))

  let is_vdd a = Bits.is_vdd (value a)
  let (>:) a b = Value (value a >: value b)
end

include Instructions.Make(Expression)
include Loop ()
include Ref (struct
    type t = Bits.t ref
  end)

let get_ref r = Expression.Reference r ;;

open Let_syntax

let rec loop_bits ~start ~end_ f =
  if Expression.(is_vdd ((>:) start end_ )) then
    return ()
  else
    let* () = f start in
    loop_bits ~start:(Expression.(+:.) start 1) ~end_ f
;;

let rec interpret (program : _ t) =
  match program with
  | Return a -> a
  | Then (ins, k) ->
    begin match ins with
    | New_ref expression ->
      interpret (k (ref (Expression.value expression)))
    | Set_ref (r, v) ->
      r := Expression.value v;
      interpret (k ())
    | For { start; end_; f; } ->
      interpret (loop_bits ~start ~end_ f >>= k)
    | _ -> raise_s [%message "Incomplete implementation, this should not have happened!"]
    end
;;