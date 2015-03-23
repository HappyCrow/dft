(* a CLI only talks to the MDS and to the local DS on the same node
   - all complex things should be handled by them and the CLI remain simple *)

open Batteries
open Printf
open Types.Protocol

module Fn = Filename
module FU = FileUtil
module Logger = Log
module Log = Log.Make (struct let section = "CLI" end) (* prefix all logs *)
module S = String
module Node = Types.Node
module File = Types.File
module FileSet = Types.FileSet
module Sock = ZMQ.Socket

let uninitialized = -1

let ds_host = ref (Utils.hostname ())
let ds_port = ref Utils.default_ds_port
let mds_host = ref "localhost"
let mds_port = ref Utils.default_mds_port

let abort msg =
  Log.fatal msg;
  exit 1

let main () =
  (* setup logger *)
  Logger.set_log_level Logger.DEBUG;
  Logger.set_output Legacy.stdout;
  Logger.color_on ();
  (* options parsing *)
  Arg.parse
    [ "-mds", Arg.String (Utils.set_host_port mds_host mds_port),
      "<host:port> MDS";
      "-ds", Arg.String (Utils.set_host_port ds_host ds_port),
      "<host:port> local DS" ]
    (fun arg -> raise (Arg.Bad ("Bad argument: " ^ arg)))
    (sprintf "usage: %s <options>" Sys.argv.(0));
  (* check options *)
  if !mds_host = "" || !mds_port = uninitialized then abort "-mds is mandatory";
  if !ds_host = "" || !ds_port = uninitialized then abort "-ds is mandatory";
  Log.info "Client of MDS %s:%d" !mds_host !mds_port;
  let mds_client_context, mds_client_socket =
    Utils.zmq_client_setup !mds_host !mds_port
  in
  (* let ds_client_context, ds_client_socket = *)
  (*   Utils.zmq_client_setup (Utils.hostname ()) !ds_port *)
  (* in *)
  (* the CLI execute just one command then exit *)
  (* we could have a batch mode, executing several commands from a file *)
  try
    let command_str = read_line () in
    let parsed_command = BatString.nsplit ~by:" " command_str in
    begin match parsed_command with
      | [] -> abort "parsed_command = []"
      | cmd :: _args ->
        begin match cmd with
          | "" -> Log.error "cmd = \"\""
          | "quit" ->
            let quit_cmd_req = For_MDS.encode (For_MDS.From_CLI (Quit_cmd_req)) in
            Sock.send mds_client_socket quit_cmd_req;
            let encoded_answer = Sock.recv mds_client_socket in
            let answer = From_MDS.decode encoded_answer in
            assert(answer = From_MDS.To_CLI Quit_cmd_ack);
            Log.info "quit ack";
          | _ -> Log.error "unhandled: %s" cmd
        end
    end
  with exn -> begin
      Log.info "exception";
      Utils.zmq_cleanup mds_client_context mds_client_socket;
      (* Utils.zmq_cleanup ds_client_context ds_client_socket; *)
      raise exn;
    end
;;

main ()