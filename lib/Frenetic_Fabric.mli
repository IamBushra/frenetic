open Core.Std
open Frenetic_Fdd
open Frenetic_Network
open Frenetic_OpenFlow
open Frenetic_NetKAT

exception IncompletePlace of string
exception NonExistentPath of string
exception NonFilterNode of policy
exception ClashException of string
exception CorrelationException of string

type place     = (switchId * portId)
type fabric    = (switchId, Frenetic_OpenFlow.flowTable) Hashtbl.t

(** Fabric generators, from a topology or policy *)
module Generators : sig
  val vlan_per_port : Net.Topology.t -> fabric
  val shortest_path : Net.Topology.t -> switchId list -> switchId list -> fabric
  val of_local_policy : policy -> switchId list -> fabric
  val of_global_policy : policy -> switchId list -> fabric
end

(** Condition related functions *)
module Condition  : sig
  type t = (Value.t option * Value.t list) FieldTable.t

  val of_pred     : pred -> t list
  val to_pred     : t -> pred
  val to_string   : t -> string

  val checked     : t -> Field.t -> bool
  val satisfy     : t -> policy list
  val undo        : t -> t -> policy list
  val places_only : t -> bool
  val is_subset   : t -> t -> bool
end

(** A dyad is an alpha/beta pair.

    The `of_policy` function is provided as a convenience, but typically Dyads
    should be constructed from an `Assemblage.t`, as described below. *)
module Dyad : sig
  type t = int * place * place * Condition.t * Action.t

  val uid : t -> int
  val src : t -> place
  val dst : t -> place
  val condition : t -> Condition.t
  val action : t -> Action.t

  val of_policy : policy -> t list
  val to_string : t -> string
end

module Assemblage : sig
  type t

  val program  : t -> policy
  val policy   : t -> policy
  val assemble : policy -> policy -> place list -> place list -> t
  val to_dyads : t -> Dyad.t list
end

(** Topology Handling: Functions for finding adjacent nodes in a given topology *)
module Topo : sig
  type t = {
    topo  : policy
  ; preds : (place, place) Hashtbl.t
  ; succs : (place, place) Hashtbl.t }

  val predecessors : policy -> (place, place) Hashtbl.t
  val successors : policy -> (place, place) Hashtbl.t
  val precedes : (place, place) Hashtbl.t -> place -> place -> portId option
  val succeeds :  (place, place) Hashtbl.t -> place -> place -> portId option
  val starts_at : (place, place) Hashtbl.t -> switchId -> Dyad.t -> bool
  val stops_at : (place, place) Hashtbl.t -> switchId -> Dyad.t -> bool

  val adjacent : t -> Dyad.t -> Dyad.t -> bool
  val go_to : t -> place -> place -> policy
  val come_from : t -> place -> place -> pred
end

val dedup : policy -> policy
val string_of_place  : place  -> string

(* val retarget : Dyad.t list -> Dyad.t list -> policy -> *)
(*   (policy list * policy list) *)
