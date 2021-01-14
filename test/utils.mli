open Hardcaml

module Recipe_back_end = Ocaml_edsl_recipe.Recipe_back_end

type t

val compile : Signal.t Recipe_back_end.t -> t
val run     : t -> Bits.t
