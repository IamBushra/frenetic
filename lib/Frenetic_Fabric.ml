open Core.Std
open Frenetic_Fdd
open Frenetic_NetKAT

module Compiler = Frenetic_NetKAT_Compiler

type place     = (switchId * portId)
type fabric    = (switchId, Frenetic_OpenFlow.flowTable) Hashtbl.t

(** Import and rename utility functions *)
let conjoin = Frenetic_NetKAT_Optimize.mk_big_and
let disjoin = Frenetic_NetKAT_Optimize.mk_big_or
let seq     = Frenetic_NetKAT_Optimize.mk_big_seq
let union   = Frenetic_NetKAT_Optimize.mk_big_union
let strip_vlan = 0xffff

let compile_local =
  let open Compiler in
  compile_local ~options:{ default_compiler_options with cache_prepare = `Keep }

(** Exceptions **)
exception IncompletePlace of string
exception NonExistentPath of string
exception NonFilterNode of policy
exception ClashException of string
exception CorrelationException of string


(** Conversion and utility functions **)
let pred_of_place ((sw,pt):place) =
  And( Test( Switch sw ), Test( Location( Physical pt )))

let place_of_options sw pt = match sw, pt with
  | Some sw, Some pt -> (sw, pt)
  | None   , Some pt -> raise (IncompletePlace
                                 (sprintf "No switch specified for port %ld" pt))
  | Some sw, None    -> raise (IncompletePlace
                                 (sprintf "No port specified for switch %Ld" sw))
  | None   , None    -> raise (IncompletePlace "No switch and port specified")

let paths_of_fdd fdd =
  let rec traverse node path =
    match FDD.unget node with
    | FDD.Branch ((v,l), t, f) ->
      let true_pred   = (v, Some l, []) in
      let true_paths  = traverse t ( true_pred::path ) in
      let false_pred  = (v, None, [l]) in
      let false_paths = traverse f ( false_pred::path ) in
      List.unordered_append true_paths false_paths
    | FDD.Leaf r ->
      [ (r, path) ] in
  traverse fdd []

let fuse field (pos, negs) (pos', negs') =
  let pos = match pos, pos' with
    | None, None   -> None
    | None, Some v
    | Some v, None -> Some v
    | Some v1, Some v2 ->
      let msg = sprintf "Field (%s) expected to have clashing values of (%s) and (%s) "
          (Field.to_string field) (Value.to_string v1) (Value.to_string v2) in
      raise (ClashException msg) in
  let negs = match negs, negs' with
    | [], [] -> []
    | vs, [] -> vs
    | [], vs -> vs
    | vs1, vs2 -> List.unordered_append vs1 vs2 in
  (pos, negs)

(* Iterate through a policy and translates Links to matches on source and *)
(* modifications to the destination *)
let rec dedup (pol:policy) : policy =
  let at_place sw pt = Filter (pred_of_place (sw,pt)) in
  let to_place sw pt =
    let sw_mod = Mod (Switch sw) in
    let pt_mod = Mod (Location (Physical pt)) in
    Seq ( sw_mod, pt_mod ) in
  match pol with
  | Filter a    -> Filter a
  | Mod hv      -> Mod hv
  | Union (p,q) -> Union(dedup p, dedup q)
  | Seq (p,q)   -> Seq(dedup p, dedup q)
  | Star p      -> Star(dedup p)
  | Link (s1,p1,s2,p2) ->
    Seq (at_place s1 p1, to_place s2 p2)
  | VLink _       -> failwith "Fabric: Cannot remove Dups from a policy with VLink"
  | Let (_,_,_,_) -> failwith "No support for Meta fields yet"

let string_of_pred = Frenetic_NetKAT_Pretty.string_of_pred
let string_of_policy = Frenetic_NetKAT_Pretty.string_of_policy

let string_of_place ((sw,pt):place) =
  sprintf "(%Ld:%ld)" sw pt

(** Fabric generators, from a topology or policy *)
module Generators = struct
  open Frenetic_OpenFlow
  open Frenetic_Network

  let mk_flow (pat:Pattern.t) (actions:group) : flow =
    { pattern = pat
    ; action = actions
    ; cookie = 0L
    ; idle_timeout = Permanent
    ; hard_timeout = Permanent
    }

  let drop = mk_flow Pattern.match_all [[[]]]

  let vlan_per_port (net:Net.Topology.t) : fabric =
    let open Net.Topology in
    let tags = Hashtbl.Poly.create ~size:(num_vertexes net) () in
    iter_edges (fun edge ->
        let src, port = edge_src edge in
        let label = vertex_to_label net src in
        let pattern = { Pattern.match_all with dlVlan =
                                                 Some (Int32.to_int_exn port)} in
        let actions = [ [ [ Modify(SetVlan (Some strip_vlan)); Output (Physical port) ] ] ] in
        let flow = mk_flow pattern actions in
        match Node.device label with
        | Node.Switch ->
          Hashtbl.Poly.change tags (Node.id label)
            ~f:(fun table -> match table with
                | Some flows -> Some( flow::flows )
                | None -> Some [flow; drop] )
        | _ -> ()) net;
    tags

  let shortest_path (net:Net.Topology.t)
      (ingress:switchId list) (egress:switchId list) : fabric =
    let open Net.Topology in
    let vertexes = vertexes net in
    let vertex_from_id swid =
      let vopt = VertexSet.find vertexes (fun v ->
          (Node.id (vertex_to_label net v)) = swid) in
      match vopt with
      | Some v -> v
      | None -> failwith (Printf.sprintf "No vertex for switch id: %Ld" swid )
    in

    let mk_flow_mod (tag:int) (port:int32) : flow =
      let pattern = { Pattern.match_all with dlVlan = Some tag } in
      let actions = [[[ Output (Physical port) ]]] in
      mk_flow pattern actions
    in


    let table = Hashtbl.Poly.create ~size:(num_vertexes net) () in
    let tag = ref 10 in
    List.iter ingress ~f:(fun swin ->
        let src = vertex_from_id swin in
        List.iter egress ~f:(fun swout ->
            if swin = swout then ()
            else
              let dst = vertex_from_id swout in
              tag := !tag + 1;
              match Net.UnitPath.shortest_path net src dst with
              | None -> ()
              | Some p ->
                List.iter p ~f:(fun edge ->
                    let src, port = edge_src edge in
                    let label = vertex_to_label net src in
                    let flow_mod = mk_flow_mod !tag port in
                    match Node.device label with
                    | Node.Switch ->
                      Hashtbl.Poly.change table (Node.id label)
                        ~f:(fun table -> match table with
                            | Some flow_mods -> Some( flow_mod::flow_mods )
                            | None -> Some [flow_mod; drop] )
                    | _ -> ())));
    table

  let of_local_policy (pol:policy) (sws:switchId list) : fabric =
    let fabric = Hashtbl.Poly.create ~size:(List.length sws) () in
    let compiled = compile_local pol in
    List.iter sws ~f:(fun swid ->
        let table = (Compiler.to_table swid compiled) in
        match Hashtbl.Poly.add fabric ~key:swid ~data:table with
        | `Ok -> ()
        | `Duplicate -> printf "Duplicate table for switch %Ld\n" swid
      ) ;
    fabric


  let of_global_policy (pol:policy) (sws:switchId list) : fabric =
    let fabric = Hashtbl.Poly.create ~size:(List.length sws) () in
    let compiled = Compiler.compile_global pol in
    List.iter sws ~f:(fun swid ->
        let table = (Compiler.to_table swid compiled) in
        match Hashtbl.Poly.add fabric ~key:swid ~data:table with
        | `Ok -> ()
        | `Duplicate -> printf "Duplicate table for switch %Ld\n" swid
      ) ;
    fabric

end

(** Topology Handling: Functions for finding adjacent nodes in a given topology *)
module Topo = struct
  type t = {
    topo  : policy
  ; preds : (place, place) Hashtbl.t
  ; succs : (place, place) Hashtbl.t }

  let predecessors (topo:policy) =
    let table = Hashtbl.Poly.create () in
    let rec populate pol = match pol with
      | Union(p1, p2) ->
        populate p1;
        populate p2
      | Link (s1,p1,s2,p2) ->
        begin match Hashtbl.Poly.add table (s2,p2) (s1,p1) with
          | `Ok -> ()
          | `Duplicate ->
            let s1', p1' = Hashtbl.Poly.find_exn table (s2,p2) in
            failwith (sprintf
                        "Duplicate detected for (%Ld:%ld) => (%Ld:%ld). Previously had (%Ld:%ld)."
                        s1 p1 s2 p2 s1' p1')
        end
      | p -> failwith (sprintf "Unexpected construct in policy: %s\n"
                         (Frenetic_NetKAT_Pretty.string_of_policy p)) in
    populate topo;
    table

  let successors (topo:policy) =
    let table = Hashtbl.Poly.create () in
    let rec populate pol = match pol with
      | Union(p1, p2) ->
        populate p1;
        populate p2
      | Link (s1,p1,s2,p2) ->
        Hashtbl.Poly.add_exn table (s1,p1) (s2,p2);
      | p -> failwith (sprintf "Unexpected construct in policy: %s\n"
                         (Frenetic_NetKAT_Pretty.string_of_policy p)) in
    populate topo;
    table

  (* Does (sw,pt) precede (sw',pt') in the topology, using the predecessor table *)
  let precedes tbl (sw,_) (sw',pt') =
    match Hashtbl.Poly.find tbl (sw',pt') with
    | Some (pre_sw,pre_pt) -> if pre_sw = sw then Some pre_pt else None
    | None -> None

  (* Does (sw,pt) succeed (sw',pt') in the topology, using the successor table *)
  let succeeds tbl (sw,_) (sw',pt') =
    match Hashtbl.Poly.find tbl (sw',pt') with
    | Some (post_sw, post_pt) -> if post_sw = sw then Some post_pt else None
    | None -> None

  (* Does the stream starting at (sw',pt') start at sw, or one hop after it *)
  let starts_at tbl sw (_,(sw',pt'),_,_,_) =
    let precedes = match Hashtbl.Poly.find tbl (sw',pt') with
      | Some (pre_sw,_) -> pre_sw = sw
      | None -> false in
    sw = sw' || precedes

  (* Does the stream ending at (sw',pt') stop at sw, or one hop before it *)
  let stops_at tbl sw (_,_,(sw',pt'),_,_) =
    let succeeds = match Hashtbl.Poly.find tbl (sw',pt') with
      | Some (post_sw, _) -> post_sw = sw
      | None -> false in
    sw = sw' || succeeds

  (* Check if the fabric stream and the policy stream start and end at the same,
     or immediately adjacent locations. This is decided using predecessor and
     successor tables. *)
  let adjacent topo (_,src,dst,_,_) fab_stream =
    starts_at topo.preds (fst src) fab_stream &&
    stops_at  topo.succs (fst dst) fab_stream

  let go_to topology ((src_sw, src_pt) as src) ((dst_sw, dst_pt) as dst) =
    let pt = if src_sw = dst_sw then dst_pt
      else match precedes topology.preds src dst with
        | Some pt -> pt
        | None ->
          failwith (sprintf "Cannot go to %s from %s in the given topology"
                      (string_of_place src) (string_of_place dst)) in
    Mod (Location (Physical pt))

  let come_from topology ((src_sw, src_pt) as src) ((dst_sw, dst_pt) as dst) =
    let pt = if src_sw = dst_sw then src_pt
      else match succeeds topology.succs dst src with
        | Some pt -> pt
        | None ->
          failwith (sprintf "Cannot go to %s from %s in the given topology"
                      (string_of_place src) (string_of_place dst)) in
    And(Test( Switch dst_sw ),
        Test( Location( Physical pt )))


end

module Condition = struct
  type t = (Value.t option * Value.t list) FieldTable.t

  let of_fdd_path (action,headers) : t =
    let tbl = FieldTable.create ~size:(List.length headers) () in
    List.iter headers ~f:(fun (field, pos, negs) ->
        FieldTable.update tbl field ~f:(function
            | None -> ( pos, negs )
            | Some c -> fuse field (pos,negs) c));
    tbl

  let of_pred (p:pred) : t list =
    let sentinel = Mod( Location( Pipe "sentinel" )) in
    let pol = Seq( Filter p, sentinel ) in
    let fdd = compile_local pol in
    let paths = paths_of_fdd fdd in
    List.fold_left paths ~init:[] ~f:(fun acc ((a,hs) as p) ->
        if String.Set.mem (Action.pipes a) "sentinel"
        then (of_fdd_path p)::acc else acc)

  let to_pred (c:t) : pred =
    let preds = FieldTable.fold c ~init:[]
        ~f:(fun ~key:field ~data:(pos, negs) acc ->
            let negs = List.map negs ~f:(fun v ->
                Neg (Pattern.to_pred (field, v))) in
            match pos with
            | None -> (conjoin negs)::acc
            | Some v ->
              let p = And(conjoin negs, Pattern.to_pred (field, v)) in p::acc) in
    conjoin preds

  (* TODO(basus): remove conversions to policies *)
  let to_string (c:t) : string =
    (string_of_pred (to_pred c))

  let checked c fld = FieldTable.mem c fld

  let satisfy (c:t) : policy list =
    FieldTable.fold c ~init:[] ~f:(fun ~key ~data acc -> match data with
        | Some pos, [] -> Mod( Pattern.to_hv (key, pos) )::acc
        | Some pos, negs ->
          if List.exists negs (fun f -> f = pos)
          then raise (ClashException (sprintf "Unsatisfiable condition %s"
                                        (to_string c)))
          else Mod( Pattern.to_hv (key, pos) )::acc
        | None, [] -> acc
        | None, negs ->
          (* TODO(basus) : this is incomplete. Need to find a predicate that
             doesn't match any of the negs. *)
          acc)

  let undo c c' =
    FieldTable.fold c ~init:[] ~f:(fun ~key ~data acc ->
        let values = FieldTable.find c' key in
        match values with
        | Some(Some v, _) -> Mod( Pattern.to_hv (key,v) )::acc
        | _ -> failwith "Cannot undo")

  let places_only c =
    FieldTable.fold c ~init:true ~f:(fun ~key ~data acc ->
        acc && (key = Field.Switch || key = Field.Location))

  let is_subset c c' =
    FieldTable.fold c ~init:true ~f:(fun ~key ~data acc ->
        acc && (FieldTable.mem c' key))

end


(** Code to convert policies to alpha/beta pairs (dyads) **)
module Dyad = struct
  type t = int * place * place * Condition.t * Action.t

  let uid (i,_,_,_,_) = i
  let src (_,p,_,_,_) = p
  let dst (_,_,p,_,_) = p
  let condition (_,_,_,c,_) = c
  let action (_,_,_,_,a) = a

  let to_string (s:t) : string =
    let uid, (sw_in, pt_in), (sw_out, pt_out), condition, action = s in
    sprintf
      "Id:%d\nFrom: Switch:%Ld Port:%ld\nTo Switch:%Ld Port:%ld\nCondition: %s\nAction: %s\n"
      uid sw_in pt_in sw_out pt_out
      (Condition.to_string condition)
      (string_of_policy (Action.to_policy action))


  (* TODO(basus): This only keep the last destination, but there might be many *)
  let destination_of_action (action:Action.t) : (switchId option * portId option * Action.t) =
    Action.Par.fold action ~init:(None, None, Action.Par.empty)
      ~f:(fun (sw,pt,acc) seq ->
          let sw, pt, seq' = Action.Seq.fold_fields seq ~init:(sw,pt,Action.Seq.empty)
              ~f:(fun ~key ~data (sw,pt,acc) ->
                  match Pattern.to_hv (key, data) with
                  | IP4Src(nwAddr, 32l) ->
                    (sw,pt, Action.Seq.add acc (Action.F key) data)
                  | IP4Dst(nwAddr, 32l) ->
                    (sw,pt, Action.Seq.add acc (Action.F key) data)
                  | Switch sw ->
                    (Some sw, pt, acc)
                  | Location(Physical pt) ->
                    (sw, Some pt, acc)
                  | hv ->
                    (sw,pt, Action.Seq.add acc (Action.F key) data)) in
          (sw, pt, Action.Par.add acc seq'))

  let of_fdd_path (action,headers) i : t =
    let update sw pt tbl field pos negs = match field, pos with
      | Field.Switch, Some( Value.Const sw' ) -> begin match sw with
          | None -> (Some sw', pt)
          | Some sw ->
            let msg = sprintf "Switch field has clashing values of %Ld and %Ld" sw sw' in
            raise (ClashException msg) end
      | Field.Location, Some( Value.Const pt' as p) -> begin match pt with
          | None -> (sw, Some(Value.to_int32_exn p))
          | Some pt ->
            let msg = sprintf "Port field has clashing values of %ld and %ld" pt
                (Value.to_int32_exn p) in
            raise (ClashException msg) end
      | _ ->
        FieldTable.update tbl field ~f:(function
            | None -> ( pos, negs )
            | Some c -> fuse field (pos,negs) c);
        (sw, pt) in
    let tbl = FieldTable.create ~size:(List.length headers) () in
    let src_sw, src_pt = List.fold_left headers ~init:(None, None)
        ~f:(fun (sw,pt) (f, p, ns) ->
            update sw pt tbl f p ns) in
    let dst_sw, dst_pt, action = destination_of_action action in
    let src = place_of_options src_sw src_pt in
    let dst = place_of_options dst_sw dst_pt in
    (i, src, dst, tbl, action)

  let of_policy (pol:policy) : t list =
    let deduped = dedup pol in
    let fdd = compile_local deduped in
    let paths = paths_of_fdd fdd in
    let dyads,_ = List.fold_left paths ~init:([],1) ~f:(fun (acc,i) ((a,hs) as p) ->
        if ( Action.is_zero a || Action.is_one a )
        then (acc,i)
        else (( of_fdd_path p i )::acc,i+1)) in
    dyads

end

module Assemblage = struct
  type t = { policy : policy
           ; topology : policy
           ; ingresses : place list
           ; egresses : place list
           ; assemblage : policy
           }

  (* Given a policy, guard it with the ingresses, sequence and iterate with the *)
  (* topology and guard with the egresses, i.e. form in;(p.t)*;p;out *)
  let assemble (policy:policy) (topology:policy) ingresses egresses : t =
    let to_filter (sw,pt) = Filter( And( Test(Switch sw),
                                         Test(Location (Physical pt)))) in
    let ings = union (List.map ingresses ~f:to_filter) in
    let egs = union (List.map egresses ~f:to_filter) in
    let assemblage = seq [ ings;
                           Star(Seq(policy, topology)); policy;
                           egs ] in
    { policy; topology; ingresses; egresses; assemblage }

  let program a = a.assemblage

  let policy a = a.policy

  let to_dyads (a:t) : Dyad.t list =
    let deduped = dedup a.assemblage in
    let fdd = compile_local deduped in
    let paths = paths_of_fdd fdd in
    let dyads,_ = List.fold_left paths ~init:([],1)
        ~f:(fun (acc,i) ((a,hs) as p) ->
            if ( Action.is_zero a || Action.is_one a )
            then (acc,i)
            else (( Dyad.of_fdd_path p i )::acc, i+1 )) in
    dyads

end
