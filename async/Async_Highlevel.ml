open Core.Std
open Async.Std

module S = SDN_Types
module Header = OpenFlow_Header
module OF1 = OpenFlow0x01
module OF1_Core = OpenFlow0x01_Core
module M1 = OF1.Message
module OF4 = OpenFlow0x04
module OF4_Core = OpenFlow0x04_Core
module M4 = OpenFlow0x04.Message

module Platform = Async_OpenFlow_Platform.Make(struct
  type t = (Header.t * Cstruct.t) sexp_opaque with sexp

  let header_of (hdr, _) = 
    hdr

  let parse hdr buf = 
    (hdr, Cstruct.set_len buf (hdr.Header.length - Header.size))

  let marshal (hdr, body) buf =
    Cstruct.blit body 0 buf 0 (hdr.Header.length - Header.size)

  let marshal' x = x

  let to_string x = 
    Sexp.to_string_hum (sexp_of_t x)
end)

module Clients = Hashtbl.Make(Platform.Client_id)

module Switches = Hashtbl.Make(VInt)

exception Handshake of Platform.Client_id.t * string

(* helper functions to pattern match on OpenFlow type_code *)
type message_code = 
  | Hello
  | EchoRequest
  | FeaturesReply
  | MultipartReply
  | Other

let int_to_message_code n = 
  let open Header in 
  if n = type_code_echo_request then EchoRequest
  else if n = type_code_hello then Hello
  else if n = type_code_features_reply then FeaturesReply
  else if n = OF4.msg_code_to_int OF4.MULTIPART_REQ then MultipartReply
  else Other

(* constants *)
let max_version = 0x04

(* handshake protocol state *)
type handshake_state = 
  | SentHello
  | SentFeaturesRequest0x01
  | SentFeaturesRequest0x04 
  | SentPortDescriptionRequest0x04 of VInt.t
  | Connected0x01 of VInt.t
  | Connected0x04 of VInt.t

(* global state *)
let clients = Clients.create ()

let switches = Switches.create ()

let platform = ref None

let get_platform () = 
  match !platform with 
  | None -> 
     failwith "Not initialized"
  | Some t -> 
     t

(* helpers to construct OpenFlow messages *)
let hello_msg version : Platform.m  =  
  let open Header in 
  ({ version = version; 
    type_code = type_code_hello;
    length = size; 
    xid = 0l; },
   Cstruct.of_string "")

let features_request_msg version : Platform.m = 
  let open Header in 
  ({ version = version;
    type_code = type_code_features_request;
    length = size;
    xid = 0l; }, 
   Cstruct.of_string "")

let echo_reply_msg version : Platform.m = 
  let open Header in 
  ({ version = version;
    type_code = type_code_echo_reply;
    length = size;
    xid = 0l; }, 
   Cstruct.of_string "")

let port_description_request_msg version : Platform.m = 
  let open Header in 
  let open OF4 in 
  let mpr = OF4_Core.PortsDescReq in 
  let bits = Cstruct.create (MultipartReq.sizeof mpr) in 
  ignore (MultipartReq.marshal bits mpr);
  ({ version = 0x04;
    type_code = msg_code_to_int MULTIPART_REQ;
    length = size;
    xid = 0l; }, 
   bits)
  
let handshake_error (c_id:Platform.Client_id.t) (str:string) : 'a = 
  raise (Handshake (c_id,str))

let send t c_id msg = 
  Platform.send t c_id msg >>| function 
    | `Sent _ -> None
    | `Drop exn -> raise exn
        
let handshake evt = 
  let open Header in 
  match evt with 
  | `Connect c_id -> 
     ignore (Clients.add clients c_id SentHello);
     send (get_platform ()) c_id (hello_msg max_version)
  | `Disconnect (c_id,_) -> 
     (match Clients.find clients c_id with 
     | Some (Connected0x01 switch_id) -> 
        ignore (Clients.remove clients c_id);
        ignore (Switches.remove switches switch_id);
        return None
     | Some _ ->  
        ignore (Clients.remove clients c_id);
        return None
     | None -> 
        return None)
  | `Message (c_id,(hdr,bits)) -> 
     let of_type_code = int_to_message_code hdr.type_code in 
     let handshake_state = Clients.find clients c_id in 
     begin 
       match of_type_code, handshake_state with
       | EchoRequest, Some _ -> 
          send (get_platform ()) c_id (echo_reply_msg hdr.version)
       | Hello, Some SentHello ->           
          let version = min hdr.version max_version in 
          let next_handshake_state = 
            match version with 
            | 0x01 -> SentFeaturesRequest0x01
            | 0x04 -> SentFeaturesRequest0x04
            | _ -> 
               handshake_error c_id 
                 (Printf.sprintf "unexpected version %d in header: %s%!" version (to_string hdr)) in 
          ignore (Clients.add clients c_id next_handshake_state);
          send (get_platform ()) c_id (features_request_msg version)
       | FeaturesReply, Some SentFeaturesRequest0x01 -> 
          begin 
            match M1.parse hdr (Cstruct.to_string bits) with 
            | (_, M1.SwitchFeaturesReply feats) -> 
               let get_port pd = VInt.Int16 pd.OF1.PortDescription.port_no in 
               let switch_id = VInt.Int64 feats.OF1.SwitchFeatures.switch_id in 
               let switch_ports = List.map feats.OF1.SwitchFeatures.ports ~f:get_port in 
               let feats = { S.switch_id = switch_id;
                             S.switch_ports = switch_ports } in 
               ignore (Clients.add clients c_id (Connected0x01 switch_id));
               ignore (Switches.add switches switch_id c_id);
               return (Some feats)
            | _ -> 
               handshake_error c_id 
                 (Printf.sprintf "expected features reply in %s%!" (to_string hdr))
          end
     | FeaturesReply, Some SentFeaturesRequest0x04 ->
        begin 
          match M4.parse hdr (Cstruct.to_string bits) with
          | (_, M4.FeaturesReply feats) -> 
             let switch_id = VInt.Int64 feats.OF4.SwitchFeatures.datapath_id in 
             ignore (Clients.add clients c_id (SentPortDescriptionRequest0x04 switch_id));
             send (get_platform ()) c_id (port_description_request_msg hdr.version)
          | _ -> 
             handshake_error c_id 
               (Printf.sprintf "expected features reply in %s%!" (to_string hdr))
        end
     | MultipartReply, Some (SentPortDescriptionRequest0x04 switch_id) -> 
        begin
          match M4.parse hdr (Cstruct.to_string bits) with 
          | (_, M4.MultipartReply (OF4_Core.PortsDescReply ports)) -> 
             let get_port pd = VInt.Int32 pd.OF4_Core.port_no in 
             let switch_ports = List.map ports ~f:get_port in 
             let feats = { S.switch_id = switch_id;
                           S.switch_ports = switch_ports } in 
             ignore (Clients.add clients c_id (Connected0x04 switch_id));
             ignore (Switches.add switches switch_id c_id);
             return (Some feats)
          | _ -> 
             handshake_error c_id 
               (Printf.sprintf "expected port description reply in %s%!" (to_string hdr))
        end
     | _ -> 
        (* TODO(jnf): error checking and/or logging here? *)
        return None
     end

let accept_switches port = 
  Platform.create port >>= fun t -> 
  platform := Some t;
  return (Pipe.filter_map' (Platform.listen t) ~f:handshake)

let send_msg0x01 c_id msg = 
  let hdr = M1.header_of 0l msg in 
  let bits = Cstruct.create (M1.size_of msg - Header.size) in 
  M1.marshal_body msg bits; 
  send (get_platform ()) c_id (hdr,bits) 

let setup_flow_table (sw:S.switchId) (tbl:S.flowTable) = 
  let c_id = match Switches.find switches sw with
    | Some c_id -> 
       c_id
    | None -> 
       failwith "No such switch" in 
  match Clients.find clients c_id with 
  | Some Connected0x01 _ -> 
     let priority = ref 65536 in
     let send_flow_mod (fl : S.flow) : unit Deferred.t =
       decr priority;
       Deferred.ignore (send_msg0x01 c_id (M1.FlowModMsg (SDN_OpenFlow0x01.from_flow !priority fl))) in 
     send_msg0x01 c_id (M1.FlowModMsg OF1_Core.delete_all_flows) >>= fun _ -> 
     Deferred.all_ignore (List.map tbl ~f:send_flow_mod)
  | Some Connected0x04 _ -> 
     failwith "NYI"
  | _ -> 
     failwith "Switch not connected"
