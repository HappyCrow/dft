open Batteries
open Printf

module FU = FileUtil

module Node = struct
  (* the rank allows to uniquely identify a node; a la MPI *)
  type t = { rank: int    ;
             host: string ;
             port: int    }
  let create rank host port =
    { rank; host; port }
  let dummy () =
    { rank = -1; host = "dummy_hostname"; port = -1 }
  let get_rank n =
    n.rank
  let get_host n =
    n.host
  let get_port n =
    n.port
  let to_string n =
    sprintf "%d.%s:%d" n.rank n.host n.port
  let to_triplet n =
    (n.rank, n.host, n.port)
  let of_string s =
    Scanf.sscanf s "%d.%s:%d" create
  let compare n1 n2 =
    BatInt.compare n1.rank n2.rank
end

module NodeSet = struct
  include Set.Make(Node)
end

module File = struct
  module Chunk = struct
    let default_size = 1024 * 1024
    type t = { rank:  int          ;
               size:  int64 option ; (* None if default_size; (Some x) else *)
               nodes: NodeSet.t    } (* which nodes have this chunk
                                        in their datastore *)
    let create rank size node =
      let nodes = NodeSet.singleton node in
      { rank; size; nodes }
    let compare c1 c2 =
      BatInt.compare c1.rank c2.rank
  end

  module ChunkSet = struct
    include Set.Make(Chunk)
    let create nb_chunks last_chunk_size node =
      let rec loop acc i =
        if i = nb_chunks - 1 then
          add (Chunk.create i last_chunk_size node) acc
        else
          let new_acc = add (Chunk.create i None node) acc in
          loop new_acc (i + 1)
      in
      if nb_chunks <= 0 then empty
      else loop empty 0
  end

  type t = { name:      string     ;
             size:      int64      ;
             stat:      FU.stat    ;
             nb_chunks: int        ;
             chunks:    ChunkSet.t }
  let create name size stat nb_chunks last_chunk_size node =
    let chunks = ChunkSet.create nb_chunks last_chunk_size node in
    { name; size; stat; nb_chunks ; chunks }
  let compare f1 f2 =
    String.compare f1.name f2.name
end

(* the status of the "filesystem" is just a set of files *)
module FileSet = struct
  include Set.Make(File)
  let dummy_stat = FU.stat "/dev/null" (* should be private *)
  (* extend module with more operations *)
  let contains_fn fn s =
    let dummy_file = File.({ name = fn;
                             size = Int64.zero;
                             stat = dummy_stat;
                             nb_chunks = 0;
                             chunks = ChunkSet.empty })
    in
    mem dummy_file s
end

(* only support Raw mode until all commands are properly working
   Compressed mode will be the next priority
   Compressed, Signed and Encrypted can be combined so there is
   a total of eight modes
   signing alone could provide some sort of authentication for
   commands which allow to control the state of the system; an
   attacker could observe the system if he is on the same network
   but not control it *)
type storage_mode = Raw | Compressed | Encrypted | Signed

module Protocol = struct

  (* naming of messages
     ------------------
     *_req: request that will need an answer
     *_ack: positive answer to a request
     *_nack: negative answer to a request
     *_push: message that doesn't need answer
     *_cmd_*: related to a command from the CLI *)

  type ds_rank = int
  type filename = string
  type chunk_id = int
  type chunk_data = string

  (* the MDS is a master, DSs are its slaves *)
  (* message types *)
  type ds_to_mds =
    | Join_push of Node.t (* a DS registering itself with the MDS *)
    | Chunk_ack of filename * chunk_id

  type mds_to_ds =
    | Send_to_req of ds_rank * filename * chunk_id
    | Quit_cmd

  type ds_to_ds =
    | Chunk of filename * chunk_id * chunk_data

  type cli_to_mds =
    | Add_file_cmd_req of File.t
    | Ls_cmd_req
    | Quit_cmd (* MDS must then send Quit to all DSs then exit itself *)

  type mds_to_cli =
    | Ls_cmd_ack of FileSet.t

  type cli_to_ds =
    | Add_file of File.t (* if op. is successful,
                            it will be followed by a
                            cli_to_mds.Add_file message.
                            If the Add_file fails, we'll have
                            to rollback the local datastore *)

  type ds_to_cli = Ok | Already_here | Is_directory | Copy_failed

  (* modules useful when sending a message *)

  module From_MDS = struct
    type t = To_DS  of mds_to_ds
           | To_CLI of mds_to_cli
    let encode (m: t): string =
      Marshal.to_string m [Marshal.No_sharing]
    let decode (s: string): t =
      (Marshal.from_string s 0: t)
  end

  module From_DS = struct
    type t = To_MDS of ds_to_mds
           | To_DS  of ds_to_ds
           | To_CLI of ds_to_cli
    let encode (m: t): string =
      Marshal.to_string m [Marshal.No_sharing]
    let decode (s: string): t =
      (Marshal.from_string s 0: t)
  end

  module From_CLI = struct
    type t = To_MDS of cli_to_mds
           | To_DS  of cli_to_ds
    let encode (m: t): string =
      Marshal.to_string m [Marshal.No_sharing]
    let decode (s: string): t =
      (Marshal.from_string s 0: t)
  end

  (* modules useful when receiving a message *)

  module For_MDS = struct
    type t = From_DS  of ds_to_mds
           | From_CLI of cli_to_mds
    let encode (m: t): string =
      Marshal.to_string m [Marshal.No_sharing]
    let decode (s: string): t =
      (Marshal.from_string s 0: t)
  end

  module For_DS = struct
    type t = From_MDS of mds_to_ds
           | From_DS  of ds_to_ds
           | From_CLI of cli_to_ds
    let encode (m: t): string =
      Marshal.to_string m [Marshal.No_sharing]
    let decode (s: string): t =
      (Marshal.from_string s 0: t)
  end

  module For_CLI = struct
    type t = From_MDS of mds_to_cli
           | From_DS  of ds_to_cli
    let encode (m: t): string =
      Marshal.to_string m [Marshal.No_sharing]
    let decode (s: string): t =
      (Marshal.from_string s 0: t)
  end

end
