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
  PasLsp.Transport in 'source\PasLsp.Transport.pas',
  PasLsp.Protocol in 'source\PasLsp.Protocol.pas',
  PasLsp.Documents in 'source\PasLsp.Documents.pas',
  PasLsp.Server in 'source\PasLsp.Server.pas';

var
  GTransport: TLspTransport;
  GServer: TLspServer;
  GJson, GReply: string;

begin
  GTransport := TLspTransport.Create;
  GServer := TLspServer.Create;
  try
    while not GServer.ExitRequested do
    begin
      if not GTransport.ReadMessage(GJson) then
        Break;   // client closed stdin: session over
      GReply := GServer.Handle(GJson);
      if GReply <> '' then
        GTransport.WriteMessage(GReply);
      for var GNote in GServer.TakeOutgoing do
        GTransport.WriteMessage(GNote);
    end;
    ExitCode := GServer.ExitCode;
  finally
    GServer.Free;
    GTransport.Free;
  end;
end.
