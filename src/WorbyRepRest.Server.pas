unit WorbyRepRest.Server;

interface

type
  TWorbyRepRestServer = class
  public
    class procedure Start;
  end;

implementation

uses
  System.IniFiles,
  System.SyncObjs,
  System.SysUtils,
  Horse,
  WorbyRepRest.Controllers.Tables;

var
  GDbGate: TCriticalSection;

class procedure TWorbyRepRestServer.Start;
var
  LIni: TIniFile;
  LPort: Integer;
  LConfigPath: string;
begin
  if not Assigned(GDbGate) then
    GDbGate := TCriticalSection.Create;

  THorse.Use(
    procedure(Req: THorseRequest; Res: THorseResponse; Next: TNextProc)
    begin
      if SameText(Req.PathInfo, '/api/geocode_progress') then
      begin
        Next;
        Exit;
      end;
      GDbGate.Enter;
      try
        Next;
      finally
        GDbGate.Leave;
      end;
    end);

  TWorbyRepRestTablesController.RegisterRoutes;

  LConfigPath := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'servidor.ini';
  LPort := 9000;

  if FileExists(LConfigPath) then
  begin
    LIni := TIniFile.Create(LConfigPath);
    try
      LPort := LIni.ReadInteger('config', 'porta', 9000);
    finally
      LIni.Free;
    end;
  end;

  Writeln('WorbyRepRest escutando na porta ' + LPort.ToString);
  THorse.Listen(LPort);
end;

initialization
  GDbGate := nil;

finalization
  GDbGate.Free;

end.

