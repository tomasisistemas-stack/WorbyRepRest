program WorbyRepRest;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  Horse,
  FireDAC.DApt,
  WorbyRepRest.Server in 'src\WorbyRepRest.Server.pas',
  WorbyRepRest.Database in 'src\WorbyRepRest.Database.pas',
  WorbyRepRest.Controllers.Tables in 'src\WorbyRepRest.Controllers.Tables.pas',
  WorbyRepRest.Metadata in 'src\WorbyRepRest.Metadata.pas';

begin
  ReportMemoryLeaksOnShutdown := True;
  try
    TWorbyRepRestServer.Start;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName + ': ' + E.Message);
      Halt(1);
    end;
  end;
end.
