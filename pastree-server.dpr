program pastree_server;

{
  PasTree LSP server — phase 1 (see SPEC.md). WIN64 ONLY, like every PasTree
  tool: a real project's closure does not fit a 32-bit address space.

  stdio carries the protocol; anything human-readable goes to stderr
  (enable with PASTREE_LSP_TRACE=1).
}

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.SyncObjs,
  PasLsp.Transport in 'source\PasLsp.Transport.pas',
  PasLsp.Protocol in 'source\PasLsp.Protocol.pas',
  PasLsp.Documents in 'source\PasLsp.Documents.pas',
  PasLsp.ProductVersion in 'source\PasLsp.ProductVersion.pas',
  PasLsp.Version in 'source\PasLsp.Version.pas',
  PasLsp.Server in 'source\PasLsp.Server.pas';

var
  GTransport: TLspTransport;
  GCancels: TLspCancelSet;
  GReader: TLspReader;
  GServer: TLspServer;
  GJson, GReply: string;
  GDone: Boolean;

begin
  // --version on STDOUT and exit, before the transport claims stdout for the
  // protocol. Deliberately checked here rather than as an LSP request: the
  // question "which build is this exe" has to be answerable without speaking
  // JSON-RPC to it, because that is how you check a deployment (the plugin
  // looks for the exe next to its BPL - `pastree-server --version` is how a
  // person confirms which one is actually there).
  if (ParamCount >= 1) and
     ((ParamStr(1) = '--version') or (ParamStr(1) = '-v')) then
  begin
    Writeln(PasLspVersionBanner);
    Exit;
  end;

  GTransport := TLspTransport.Create;
  GCancels := TLspCancelSet.Create;
  GReader := TLspReader.Create(GTransport, GCancels);
  GServer := TLspServer.Create(GCancels);
  try
    // Dispatch loop: the READER thread owns stdin (so $/cancelRequest is
    // seen even while a handler waits out an analysis); this thread owns
    // everything else, including all stdout writes. A pop timeout is the
    // idle tick — it finalizes finished background analyses, which is how
    // diagnostics reach the client when no request follows an edit.
    GDone := False;
    while not (GDone or GServer.ExitRequested) do
    begin
      case GReader.Pop(GJson) of
        wrSignaled:
          if GJson = '' then
            GDone := True   // EOF sentinel: client closed stdin
          else
          begin
            GReply := GServer.Handle(GJson);
            if GReply <> '' then
              GTransport.WriteMessage(GReply);
          end;
        wrTimeout:
          GServer.Idle;
      else
        GDone := True;   // queue shut down
      end;
      for var GNote in GServer.TakeOutgoing do
        GTransport.WriteMessage(GNote);
    end;
    ExitCode := GServer.ExitCode;
  finally
    GServer.Free;
    // Deliberately NOT freeing GReader: its thread may sit in a blocking
    // stdin read that nothing can interrupt, and process exit (right here)
    // is the one clean way out. Freeing the rest first is safe — the reader
    // touches only the transport's IN stream and the cancel set.
  end;
end.
