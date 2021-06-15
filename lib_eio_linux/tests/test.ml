open Eio.Std

let () =
  Logs.(set_level ~all:true (Some Debug));
  Logs.set_reporter @@ Logs.format_reporter ();
  Printexc.record_backtrace true

let read_one_byte ~sw r =
  Fibre.fork ~sw ~exn_turn_off:true (fun () ->
      let r = Option.get (Eio_linux.Objects.get_fd_opt r) in
      Eio_linux.await_readable r;
      let b = Bytes.create 1 in
      let got = Unix.read (Eio_linux.FD.to_unix r) b 0 1 in
      assert (got = 1);
      Bytes.to_string b
    )

let test_poll_add () =
  Eio_linux.run @@ fun _stdenv ->
  Switch.top @@ fun sw ->
  let r, w = Eio_linux.pipe sw in
  let thread = read_one_byte ~sw r in
  Fibre.yield ();
  let w = Option.get (Eio_linux.Objects.get_fd_opt w) in
  Eio_linux.await_writable w;
  let sent = Unix.write (Eio_linux.FD.to_unix w) (Bytes.of_string "!") 0 1 in
  assert (sent = 1);
  let result = Promise.await thread in
  Alcotest.(check string) "Received data" "!" result

let test_poll_add_busy () =
  Eio_linux.run ~queue_depth:1 @@ fun _stdenv ->
  Switch.top @@ fun sw ->
  let r, w = Eio_linux.pipe sw in
  let a = read_one_byte ~sw r in
  let b = read_one_byte ~sw r in
  Fibre.yield ();
  let w = Option.get (Eio_linux.Objects.get_fd_opt w) |> Eio_linux.FD.to_unix in
  let sent = Unix.write w (Bytes.of_string "!!") 0 2 in
  assert (sent = 2);
  let a = Promise.await a in
  Alcotest.(check string) "Received data" "!" a;
  let b = Promise.await b in
  Alcotest.(check string) "Received data" "!" b

(* Write a string to a pipe and read it out again. *)
let test_copy () =
  Eio_linux.run ~queue_depth:2 @@ fun _stdenv ->
  Switch.top @@ fun sw ->
  let msg = "Hello!" in
  let from_pipe, to_pipe = Eio_linux.pipe sw in
  let buffer = Buffer.create 20 in
  Fibre.both ~sw
    (fun () -> Eio.Flow.copy from_pipe (Eio.Flow.buffer_sink buffer))
    (fun () ->
       Eio.Flow.copy (Eio.Flow.string_source msg) to_pipe;
       Eio.Flow.copy (Eio.Flow.string_source msg) to_pipe;
       Eio.Flow.close to_pipe
    );
  Alcotest.(check string) "Copy correct" (msg ^ msg) (Buffer.contents buffer);
  Eio.Flow.close from_pipe

(* Write a string via 2 pipes. The copy from the 1st to 2nd pipe will be optimised and so tests a different code-path. *)
let test_direct_copy () =
  Eio_linux.run ~queue_depth:4 @@ fun _stdenv ->
  Switch.top @@ fun sw ->
  let msg = "Hello!" in
  let from_pipe1, to_pipe1 = Eio_linux.pipe sw in
  let from_pipe2, to_pipe2 = Eio_linux.pipe sw in
  let buffer = Buffer.create 20 in
  let to_output = Eio.Flow.buffer_sink buffer in
  Switch.top (fun sw ->
      Fibre.fork_ignore ~sw (fun () -> Ctf.label "copy1"; Eio.Flow.copy from_pipe1 to_pipe2; Eio.Flow.close to_pipe2);
      Fibre.fork_ignore ~sw (fun () -> Ctf.label "copy2"; Eio.Flow.copy from_pipe2 to_output);
      Eio.Flow.copy (Eio.Flow.string_source msg) to_pipe1;
      Eio.Flow.close to_pipe1;
    );
  Alcotest.(check string) "Copy correct" msg (Buffer.contents buffer);
  Eio.Flow.close from_pipe1;
  Eio.Flow.close from_pipe2

let () =
  let open Alcotest in
  run "eioio" [
    "io", [
      test_case "copy"          `Quick test_copy;
      test_case "direct_copy"   `Quick test_direct_copy;
      test_case "poll_add"      `Quick test_poll_add;
      test_case "poll_add_busy" `Quick test_poll_add_busy;
    ];
  ]
