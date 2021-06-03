open Fibreslib

(** A base class for objects that can be queried at runtime for extra features. *)
module Generic = struct
  type 'a ty = ..
  (** An ['a ty] is a query for a feature of type ['a]. *)

  class type t = object
    method probe : 'a. 'a ty -> 'a option
  end

  let probe (t : #t) ty = t#probe ty
end

(** Byte streams. *)
module Flow = struct
  class type close = object
    method close : unit
  end

  let close (t : #close) = t#close

  class virtual read = object
    method virtual read_into : Cstruct.t -> int
  end

  (** [read_into buf] reads one or more bytes into [buf].
      It returns the number of bytes written (which may be less than the
      buffer size even if there is more data to be read).
      [buf] must not be zero-length.
      @raise End_of_file if there is no more data to read *)
  let read_into (t : #read) buf =
    let got = t#read_into buf in
    assert (got > 0);
    got

  (** Producer base class. *)
  class virtual source = object (_ : #Generic.t)
    method probe _ = None
    inherit read
  end

  let string_source s : source =
    object
      inherit source

      val mutable data = Cstruct.of_string s

      method read_into buf =
        match Cstruct.length data with
        | 0 -> raise End_of_file
        | remaining ->
          let len = min remaining (Cstruct.length buf) in
          Cstruct.blit data 0 buf 0 len;
          data <- Cstruct.shift data len;
          len
    end

  let cstruct_source data : source =
    object
      val mutable data = data

      inherit source

      method read_into dst =
        let avail, src = Cstruct.fillv ~dst ~src:data in
        if avail = 0 then raise End_of_file;
        data <- src;
        avail
    end

  class virtual write = object
    method virtual write : 'a. (#source as 'a) -> unit
  end

  (** [copy src dst] copies data from [src] to [dst] until end-of-file. *)
  let copy (src : #source) (dst : #write) = dst#write src

  let copy_string s = copy (string_source s)

  (** Consumer base class. *)
  class virtual sink = object (_ : #Generic.t)
    method probe _ = None
    inherit write
  end

  let buffer_sink b =
    object
      inherit sink

      method write src =
        let buf = Cstruct.create 4096 in
        try
          while true do
            let got = src#read_into buf in
            Buffer.add_string b (Cstruct.to_string ~len:got buf)
          done
        with End_of_file -> ()
    end

  (** Bidirectional stream base class. *)
  class virtual two_way = object (_ : #Generic.t)
    method probe _ = None
    inherit read
    inherit write

    method virtual shutdown : Unix.shutdown_command -> unit
  end

  let shutdown (t : #two_way) = t#shutdown
end

module Network = struct
  module Sockaddr = struct
    type t = Unix.sockaddr

    let pp f = function
      | Unix.ADDR_UNIX path ->
        Format.fprintf f "unix:%s" path
      | Unix.ADDR_INET (addr, port) ->
        Format.fprintf f "inet:%s:%d" (Unix.string_of_inet_addr addr) port
  end

  module Listening_socket = struct
    class virtual t = object
      method virtual close : unit
      method virtual listen : int -> unit
      method virtual accept_sub :
        sw:Switch.t ->
        on_error:(exn -> unit) ->
        (sw:Switch.t -> <Flow.two_way; Flow.close> -> Sockaddr.t -> unit) ->
        unit
    end

    let listen (t : #t) = t#listen

    (** [accept t fn] waits for a new connection to [t] and then runs [fn ~sw flow client_addr] in a new fibre,
        created with [Fibre.fork_sub_ignore].
        [flow] will be closed automatically when the sub-switch is finished, if not already closed by then. *)
    let accept_sub (t : #t) = t#accept_sub
  end

  class virtual t = object
    method virtual bind : reuse_addr:bool -> sw:Switch.t -> Sockaddr.t -> Listening_socket.t
    method virtual connect : sw:Switch.t -> Sockaddr.t -> <Flow.two_way; Flow.close>
  end

  (** [bind ~sw t addr] is a new listening socket bound to local address [addr].
      The new socket will be closed when [sw] finishes, unless closed manually first. *)
  let bind ?(reuse_addr=false) (t:#t) = t#bind ~reuse_addr

  (** [connect t ~sw addr] is a new socket connected to remote address [addr].
      The new socket will be closed when [sw] finishes, unless closed manually first. *)
  let connect (t:#t) = t#connect
end

(** The standard environment of a process. *)
module Stdenv = struct
  type t = <
    stdin  : Flow.source;
    stdout : Flow.sink;
    stderr : Flow.sink;
    network : Network.t;
  >

  let stdin  (t : <stdin  : #Flow.source; ..>) = t#stdin
  let stdout (t : <stdout : #Flow.sink;   ..>) = t#stdout
  let stderr (t : <stderr : #Flow.sink;   ..>) = t#stderr

  let network (t : <network : #Network.t; ..>) = t#network
end
