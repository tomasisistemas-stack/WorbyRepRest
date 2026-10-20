unit WorbyRepRest.Database;

interface

uses
  System.Classes,
  System.IniFiles,
  System.IOUtils,
  System.JSON,
  System.Net.HttpClient,
  System.NetEncoding,
  System.SysUtils,
  System.SyncObjs,
  Data.DB,
  FireDAC.Comp.Client,
  FireDAC.DApt,
  FireDAC.DApt.Intf,
  FireDAC.Phys,
  FireDAC.Phys.PG,
  FireDAC.Phys.PGDef,
  FireDAC.Stan.Async,
  FireDAC.Stan.Def,
  FireDAC.Stan.Error,
  FireDAC.Stan.Intf,
  FireDAC.Stan.Option,
  FireDAC.Stan.Param,
  WorbyRepRest.Metadata;

type
  TEnderecoGeocode = record
    Logradouro: string;
    Numero: string;
    Bairro: string;
    Cidade: string;
    UF: string;
    CEP: string;
  end;

  TWorbyRepRestDatabase = class
  private
    class var FConnection: TFDConnection;
    class var FPGDriverLink: TFDPhysPgDriverLink;
    class function CloneJsonObject(AObject: TJSONObject): TJSONObject;
    class procedure ConfigureConnection;
    class procedure AssignParamFromJson(AParam: TFDParam; AValue: TJSONValue; const AFieldName: string = '');
    class function ConfigFileName: string;
    class procedure ExecuteInsertObject(AConnection: TFDConnection;
      const ATableName: string; AData: TJSONObject);
    class function ExecuteInsertObjectReturning(AConnection: TFDConnection;
      const ATableName: string; AData: TJSONObject; const AReturningField: string): Variant;
    class function GetConnection: TFDConnection;
    class function FieldValueToJson(AField: TField): TJSONValue;
    class function ParseApiDate(const AValue: string; const ADefault: TDateTime): TDateTime;
    class function ParseApiDateTime(const AValue: string; const ADefault: TDateTime): TDateTime;
    class function EncodeUrlParam(const AValue: string): string;
    class function ExpandSiglasEndereco(const AEndereco: string): string;
    class function GeocodeAddress(const AEndereco: TEnderecoGeocode; out ALatitude, ALongitude: string): Boolean;
    class function GetClienteEnderecoGeocode(ACodCliente: Int64): TEnderecoGeocode;
    class procedure SetJsonString(AObject: TJSONObject; const AName, AValue: string);
    class procedure PreencherGeolocalizacaoClientes(AClientes: TJSONArray);
    class function JsonValueCI(AObject: TJSONObject; const AName: string): TJSONValue;
    class function SqliteLiteral(AValue: TJSONValue; const AFieldName: string = ''): string;
    class function SqliteIdent(const AValue: string): string;
    class function CopyScriptThroughPostgresFile(const AScript: string): string;
    class function CsvLineToText(const ALine: string): string;
    class procedure EnsureRepresentanteSincronizacaoTable;
    class procedure EnsureRepresentanteSqliteBackupColumns;
    class procedure LogSyncAuditError(const AText: string);
    class procedure BeginGeocodeProgress(const ACodRepresentante: string; ATotal: Integer);
    class procedure UpdateGeocodeProgress(AProcessed, AUpdated, ATotal: Integer);
    class procedure EndGeocodeProgress;
  public
    class function GetGeocodeProgress(const ACodRepresentante: string): TJSONObject;
    class destructor Destroy;
    class function ExecuteQuery(const ASql: string; const AParams: array of Variant): TFDQuery;
    class function QueryToJsonArray(AQuery: TFDQuery): TJSONArray;
    class function QueryRowToJson(AQuery: TFDQuery; const AIgnoreFields: array of string): TJSONObject;
    class function ListTable(const ATable: TTableInfo; ALimit: Integer; AOffset: Integer;
      const ACodRepresentante: string; const ADataUltSincronizacao: string = '';
      const ANumDocsCsv: string = ''): TJSONArray;
    class function CountTable(const ATable: TTableInfo; const ACodRepresentante: string;
      const ADataUltSincronizacao: string = ''; const ANumDocsCsv: string = ''): Integer;
    class function BuildSyncScript(const ACodRepresentante: string; ATables: TJSONArray;
      ASchema: TJSONObject; ADataUltSincronizacao: TJSONObject; const AVersao: string = ''): TJSONObject;
    class function GetById(const ATableName, APrimaryKey: string;
      APrimaryKeyType: TTableKeyType; const AValue: string): TJSONObject;
    class function GetClienteByDocumento(const ADocumento: string): TJSONObject;
    class function GetMesesDashboard(ACodRepresentante: Integer): TJSONArray;
    class function GetMetaRepresentante(ACodRepresentante: Integer; const AMes: string): TJSONObject;
    class function GetPedidosFaturadosDashboard(ACodRepresentante: Integer; const AMes, AStatus: string;
      ADiaInicial, ADiaFinal: Integer; const ABusca: string): TJSONObject;
    class function UpsertCliente(ACliente: TJSONObject): TJSONObject;
    class function InsertRepresentanteLocalizacao(ALocalizacao: TJSONObject): TJSONObject;
    class function UpsertRepresentanteKmDiario(AResumo: TJSONObject): TJSONObject;
    class function UpsertClienteVisita(AVisita: TJSONObject): TJSONObject;
    class function SaveRepresentanteSqliteBackup(ABackup: TJSONObject): TJSONObject;
    class function GetRepresentanteSqliteBackup(ACodRepresentante: Integer): TJSONObject;
    class function InsertPedido(AVendas1: TJSONObject; AVendas2: TJSONArray): TJSONObject;
    class function InsertPedidosDigitados(APedidos: TJSONArray;
      const ACodRepresentante: string = ''): TJSONObject;
    class function LoginTbusu(const ALogin, ASenha: string): TJSONObject;
    class procedure RegistrarSincronizacaoRepresentante(const ACodRepresentante, AOrigem: string;
      const AVersao: string = '');
  end;

implementation

uses
  System.Variants,
  System.DateUtils,
  System.Math,
  Winapi.Windows;

var
  GGeoProgressLock: TCriticalSection;
  GGeoProgressRep: string;
  GGeoProgressTotal: Integer;
  GGeoProgressProcessed: Integer;
  GGeoProgressUpdated: Integer;
  GGeoProgressActive: Boolean;

const
  // Configure GEOAPIFY_API_KEY / LOCATIONIQ_API_KEY no ambiente do servidor ou substitua as chaves abaixo.
  CGeoapifyKey = '5dbc34002e024da899f2c02920004bee';
  CLocationIQKey = 'pk.d5be03405b5244d1f56bf8bda2b1e798';
  CMaxClienteSyncPageSize = 500;
  CGeocodeClientesAtivo = False;

class procedure TWorbyRepRestDatabase.LogSyncAuditError(const AText: string);
var
  LPath: string;
begin
  try
    LPath := TPath.Combine(ExtractFilePath(ParamStr(0)), 'representante_sincronizacao.log');
    TFile.AppendAllText(LPath, FormatDateTime('yyyy-mm-dd hh:nn:ss', Now) + ' ' + AText + sLineBreak, TEncoding.UTF8);
  except
  end;
end;
class procedure TWorbyRepRestDatabase.BeginGeocodeProgress(const ACodRepresentante: string; ATotal: Integer);
begin
  GGeoProgressLock.Enter;
  try
    GGeoProgressRep := ACodRepresentante;
    GGeoProgressTotal := ATotal;
    GGeoProgressProcessed := 0;
    GGeoProgressUpdated := 0;
    GGeoProgressActive := True;
  finally
    GGeoProgressLock.Leave;
  end;
end;

class procedure TWorbyRepRestDatabase.UpdateGeocodeProgress(AProcessed, AUpdated, ATotal: Integer);
begin
  GGeoProgressLock.Enter;
  try
    GGeoProgressProcessed := AProcessed;
    GGeoProgressUpdated := AUpdated;
    GGeoProgressTotal := ATotal;
  finally
    GGeoProgressLock.Leave;
  end;
end;

class procedure TWorbyRepRestDatabase.EndGeocodeProgress;
begin
  GGeoProgressLock.Enter;
  try
    GGeoProgressActive := False;
  finally
    GGeoProgressLock.Leave;
  end;
end;

class function TWorbyRepRestDatabase.GetGeocodeProgress(const ACodRepresentante: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  GGeoProgressLock.Enter;
  try
    if GGeoProgressActive and ((Trim(ACodRepresentante) = '') or
      SameText(GGeoProgressRep, ACodRepresentante)) then
      Result.AddPair('active', TJSONTrue.Create)
    else
      Result.AddPair('active', TJSONFalse.Create);
    Result.AddPair('total', TJSONNumber.Create(GGeoProgressTotal));
    Result.AddPair('processados', TJSONNumber.Create(GGeoProgressProcessed));
    Result.AddPair('atualizados', TJSONNumber.Create(GGeoProgressUpdated));
    if GGeoProgressTotal > 0 then
      Result.AddPair('percentual', TJSONNumber.Create(Round(GGeoProgressProcessed / GGeoProgressTotal * 100)))
    else
      Result.AddPair('percentual', TJSONNumber.Create(0));
  finally
    GGeoProgressLock.Leave;
  end;
end;

class procedure TWorbyRepRestDatabase.EnsureRepresentanteSqliteBackupColumns;
var
  LConnection: TFDConnection;
  LQuery: TFDQuery;

  function ColumnExists(const AColumnName: string): Boolean;
  begin
    LQuery.Close;
    LQuery.SQL.Text :=
      'select 1 from information_schema.columns ' +
      'where table_schema = ''public'' and table_name = ''representante'' and column_name = :column_name';
    LQuery.ParamByName('column_name').AsString := AColumnName;
    LQuery.Open;
    Result := not LQuery.IsEmpty;
  end;

begin
  LConnection := GetConnection;
  LQuery := TFDQuery.Create(nil);
  try
    LQuery.Connection := LConnection;
    if not ColumnExists('backup_sqlite') then
      LConnection.ExecSQL('alter table public.representante add column backup_sqlite bytea');
    if not ColumnExists('backup_sqlite_datahora') then
      LConnection.ExecSQL('alter table public.representante add column backup_sqlite_datahora timestamp without time zone');
    if not ColumnExists('backup_sqlite_versao') then
      LConnection.ExecSQL('alter table public.representante add column backup_sqlite_versao varchar(30)');
    if not ColumnExists('backup_sqlite_tamanho') then
      LConnection.ExecSQL('alter table public.representante add column backup_sqlite_tamanho bigint');
  finally
    LQuery.Free;
  end;
end;
class procedure TWorbyRepRestDatabase.EnsureRepresentanteSincronizacaoTable;
var
  LConnection: TFDConnection;
  LQuery: TFDQuery;
  LTableExists: Boolean;
  LIndexExists: Boolean;
  LVersaoExists: Boolean;
begin
  LConnection := GetConnection;
  LQuery := TFDQuery.Create(nil);
  try
    LQuery.Connection := LConnection;

    LQuery.SQL.Text :=
      'select 1 from information_schema.tables ' +
      'where table_schema = ''public'' and table_name = ''representante_sincronizacao''';
    LQuery.Open;
    LTableExists := not LQuery.IsEmpty;
    LQuery.Close;

    if not LTableExists then
      LConnection.ExecSQL(
        'create table public.representante_sincronizacao (' +
        'id bigint not null primary key, ' +
        'cod_representante integer not null, ' +
        'datahora timestamp without time zone default now() not null, ' +
        'origem varchar(40), ' +
        'versao varchar(30), ' +
        'created_at timestamp without time zone default now() not null' +
        ')'
      );

    LQuery.SQL.Text :=
      'select 1 from information_schema.columns ' +
      'where table_schema = ''public'' and table_name = ''representante_sincronizacao'' ' +
      'and column_name = ''versao''';
    LQuery.Open;
    LVersaoExists := not LQuery.IsEmpty;
    LQuery.Close;

    if not LVersaoExists then
      LConnection.ExecSQL('alter table public.representante_sincronizacao add column versao varchar(30)');

    LQuery.SQL.Text :=
      'select 1 from pg_indexes ' +
      'where schemaname = ''public'' and indexname = ''idx_representante_sincronizacao_rep_datahora''';
    LQuery.Open;
    LIndexExists := not LQuery.IsEmpty;
    LQuery.Close;

    if not LIndexExists then
      LConnection.ExecSQL(
        'create index idx_representante_sincronizacao_rep_datahora ' +
        'on public.representante_sincronizacao (cod_representante, datahora desc)'
      );
  finally
    LQuery.Free;
  end;
end;

class procedure TWorbyRepRestDatabase.RegistrarSincronizacaoRepresentante(const ACodRepresentante, AOrigem,
  AVersao: string);
var
  LCodRepresentante: Integer;
  LConnection: TFDConnection;
  LQuery: TFDQuery;
  LId: Int64;
begin
  LCodRepresentante := StrToIntDef(Trim(ACodRepresentante), 0);
  if LCodRepresentante <= 0 then
    Exit;

  try
    EnsureRepresentanteSincronizacaoTable;
    LConnection := GetConnection;
    LQuery := TFDQuery.Create(nil);
    try
      LQuery.Connection := LConnection;
      LQuery.SQL.Text := 'select coalesce(max(id), 0) + 1 from public.representante_sincronizacao';
      LQuery.Open;
      LId := LQuery.Fields[0].AsLargeInt;
      LQuery.Close;

      LQuery.SQL.Text :=
        'insert into public.representante_sincronizacao (id, cod_representante, datahora, origem, versao) ' +
        'values (:id, :cod_representante, now(), :origem, :versao)';
      LQuery.ParamByName('id').AsLargeInt := LId;
      LQuery.ParamByName('cod_representante').AsInteger := LCodRepresentante;
      LQuery.ParamByName('origem').AsString := Copy(Trim(AOrigem), 1, 40);
      LQuery.ParamByName('versao').AsString := Copy(Trim(AVersao), 1, 30);
      LQuery.ExecSQL;
    finally
      LQuery.Free;
    end;
  except
    on E: Exception do
      LogSyncAuditError('Erro ao registrar sincronizacao rep=' + ACodRepresentante + ' origem=' + AOrigem + ': ' + E.ClassName + ' - ' + E.Message);
  end;
end;
class destructor TWorbyRepRestDatabase.Destroy;
begin
  FreeAndNil(FConnection);
  FreeAndNil(FPGDriverLink);
end;

class function TWorbyRepRestDatabase.CloneJsonObject(AObject: TJSONObject): TJSONObject;
begin
  if not Assigned(AObject) then
    Exit(nil);
  Result := TJSONObject.ParseJSONValue(AObject.ToJSON) as TJSONObject;
end;

class procedure TWorbyRepRestDatabase.AssignParamFromJson(AParam: TFDParam;
  AValue: TJSONValue; const AFieldName: string);
var
  LText: string;
  LInt: Int64;
  LFloat: Double;
  LFS: TFormatSettings;
  LDate: TDateTime;
begin
  if (AValue = nil) or (AValue is TJSONNull) then
  begin
    if AParam.DataType = ftUnknown then
    begin
      if SameText(AFieldName, 'dtadoc') or
         SameText(AFieldName, 'dta_emissao') or
         SameText(AFieldName, 'dta_saida') or
         SameText(AFieldName, 'data_mov') or
         SameText(AFieldName, 'dta_vencimento_consig') then
        AParam.DataType := ftDate
      else if SameText(AFieldName, 'hora') then
        AParam.DataType := ftTime
      else if (Copy(LowerCase(AFieldName), 1, 4) = 'cod_') or
              SameText(AFieldName, 'id') or
              SameText(AFieldName, 'numdoc') or
              SameText(AFieldName, 'id_cor') or
              SameText(AFieldName, 'id_tamanho') or
              SameText(AFieldName, 'qtd_parcelas') or
              SameText(AFieldName, 'status_nfe') or
              SameText(AFieldName, 'status_nfe_dev') then
        AParam.DataType := ftLargeint
      else if SameText(AFieldName, 'qtd') or
              SameText(AFieldName, 'preco') or
              SameText(AFieldName, 'sub_total') or
              SameText(AFieldName, 'desconto') or
              SameText(AFieldName, 'volume') or
              SameText(AFieldName, 'preco_bruto') or
              SameText(AFieldName, 'sub_total_bruto') or
              SameText(AFieldName, 'tot_bruto') or
              SameText(AFieldName, 'tot_liquido') or
              SameText(AFieldName, 'tot_liquido_ant') or
              SameText(AFieldName, 'vlr_comissao') then
        AParam.DataType := ftFloat
      else
        AParam.DataType := ftString;
    end;
    AParam.Clear;
    Exit;
  end;

  if AValue is TJSONTrue then
  begin
    AParam.AsBoolean := True;
    Exit;
  end;

  if AValue is TJSONFalse then
  begin
    AParam.AsBoolean := False;
    Exit;
  end;

  if AValue is TJSONNumber then
  begin
    LText := TJSONNumber(AValue).ToJSON;
    if Pos('.', LText) > 0 then
    begin
      LFS := TFormatSettings.Create;
      LFS.DecimalSeparator := '.';
      if not TryStrToFloat(LText, LFloat, LFS) then
        raise Exception.Create('Numero JSON invalido: ' + LText);
      AParam.AsFloat := LFloat;
    end
    else
    begin
      if not TryStrToInt64(LText, LInt) then
        raise Exception.Create('Inteiro JSON invalido: ' + LText);
      AParam.AsLargeInt := LInt;
    end;
    Exit;
  end;

  LText := AValue.Value;
  if LText = '' then
  begin
    AParam.Clear;
    Exit;
  end;

  // Campos conhecidos de data/hora para evitar erro de cast no PostgreSQL
  if SameText(AFieldName, 'dtadoc') or
     SameText(AFieldName, 'dta_emissao') or
     SameText(AFieldName, 'dta_saida') or
     SameText(AFieldName, 'data_mov') or
     SameText(AFieldName, 'dta_vencimento_consig') then
  begin
    if TryISO8601ToDate(LText, LDate, True) or TryISO8601ToDate(LText, LDate, False) then
    begin
      AParam.DataType := ftDate;
      AParam.AsDate := DateOf(LDate);
      Exit;
    end;

    if TryStrToDate(LText, LDate) then
    begin
      AParam.DataType := ftDate;
      AParam.AsDate := DateOf(LDate);
      Exit;
    end;
  end;

  if SameText(AFieldName, 'hora') then
  begin
    if TryStrToTime(LText, LDate) then
    begin
      AParam.DataType := ftTime;
      AParam.AsDateTime := Frac(LDate);
      Exit;
    end;
  end;

  // Campos num�ricos podem vir como string no JSON do app
  if (Copy(LowerCase(AFieldName), 1, 4) = 'cod_') or
     SameText(AFieldName, 'id') or
     SameText(AFieldName, 'numdoc') or
     SameText(AFieldName, 'id_cor') or
     SameText(AFieldName, 'id_tamanho') or
     SameText(AFieldName, 'qtd_parcelas') or
     SameText(AFieldName, 'status_nfe') or
     SameText(AFieldName, 'status_nfe_dev') then
  begin
    if TryStrToInt64(Trim(LText), LInt) then
    begin
      AParam.DataType := ftLargeint;
      AParam.AsLargeInt := LInt;
      Exit;
    end;
  end;

  if SameText(AFieldName, 'qtd') or
     SameText(AFieldName, 'preco') or
     SameText(AFieldName, 'sub_total') or
     SameText(AFieldName, 'desconto') or
     SameText(AFieldName, 'volume') or
     SameText(AFieldName, 'preco_bruto') or
     SameText(AFieldName, 'sub_total_bruto') or
     SameText(AFieldName, 'tot_bruto') or
     SameText(AFieldName, 'tot_liquido') or
     SameText(AFieldName, 'tot_liquido_ant') or
     SameText(AFieldName, 'vlr_comissao') then
  begin
    LFS := TFormatSettings.Create;
    LFS.DecimalSeparator := '.';
    if TryStrToFloat(StringReplace(LText, ',', '.', [rfReplaceAll]), LFloat, LFS) then
    begin
      AParam.DataType := ftFloat;
      AParam.AsFloat := LFloat;
      Exit;
    end;
  end;

  AParam.AsString := LText;
end;

class procedure TWorbyRepRestDatabase.ConfigureConnection;
var
  LIni: TIniFile;
  LPath: string;
  LServerIndex: string;
  LVendorLib: string;
  LDllDir: string;
begin
  LPath := ConfigFileName;
  if not FileExists(LPath) then
    raise Exception.Create('Arquivo servidor.ini nao encontrado em ' + LPath);

  LIni := TIniFile.Create(LPath);
  try
    if FPGDriverLink = nil then
      FPGDriverLink := TFDPhysPgDriverLink.Create(nil);

    LVendorLib := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'libpq.dll';
    if not FileExists(LVendorLib) then
      LVendorLib := 'C:\Tomasi Sistemas\WorbyRepRest\Win32\Debug\libpq.dll';
    if FileExists(LVendorLib) then
    begin
      LDllDir := IncludeTrailingPathDelimiter(ExtractFilePath(LVendorLib));
      SetDllDirectory(PChar(LDllDir));
      SetEnvironmentVariable('PATH', PChar(LDllDir + ';' + GetEnvironmentVariable('PATH')));
      FPGDriverLink.VendorLib := LVendorLib;
    end;

    LServerIndex := LIni.ReadString('config', 'servidor_padrao', '0');

    FConnection.Params.Clear;
    FConnection.Params.Add('DriverID=PG');
    FConnection.Params.Add('Server=' + Trim(LIni.ReadString(LServerIndex, 'servidor', '')));
    FConnection.Params.Add('Port=' + Trim(LIni.ReadString(LServerIndex, 'porta', '5432')));
    FConnection.Params.Add('Database=' + Trim(LIni.ReadString(LServerIndex, 'Path', '')));
    FConnection.Params.Add('User_Name=' + Trim(LIni.ReadString(LServerIndex, 'usuario', 'postgres')));
    FConnection.Params.Add('Password=' + LIni.ReadString(LServerIndex, 'senha', ''));
    FConnection.LoginPrompt := False;
  finally
    LIni.Free;
  end;
end;

class function TWorbyRepRestDatabase.ConfigFileName: string;
begin
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'servidor.ini';
end;

class procedure TWorbyRepRestDatabase.ExecuteInsertObject(AConnection: TFDConnection;
  const ATableName: string; AData: TJSONObject);
var
  LFields: TStringList;
  LParams: TStringList;
  LQuery: TFDQuery;
  I: Integer;
begin
  if not Assigned(AData) or (AData.Count = 0) then
    raise Exception.Create('Objeto JSON para insercao nao pode estar vazio');

  LFields := TStringList.Create;
  LParams := TStringList.Create;
  LQuery := TFDQuery.Create(nil);
  try
    for I := 0 to AData.Count - 1 do
    begin
      LFields.Add(AData.Pairs[I].JsonString.Value);
      LParams.Add(':p' + I.ToString);
    end;

    LQuery.Connection := AConnection;
    LQuery.SQL.Text := Format(
      'insert into %s (%s) values (%s)',
      [ATableName, LFields.CommaText, LParams.CommaText]
    );

    for I := 0 to AData.Count - 1 do
    begin
      // default defensivo para evitar parametro com tipo desconhecido no PG
      if LQuery.Params[I].DataType = ftUnknown then
        LQuery.Params[I].DataType := ftString;
      AssignParamFromJson(LQuery.Params[I], AData.Pairs[I].JsonValue, AData.Pairs[I].JsonString.Value);
    end;

    LQuery.ExecSQL;
  finally
    LQuery.Free;
    LParams.Free;
    LFields.Free;
  end;
end;

class function TWorbyRepRestDatabase.ExecuteInsertObjectReturning(
  AConnection: TFDConnection; const ATableName: string; AData: TJSONObject;
  const AReturningField: string): Variant;
var
  LFields: TStringList;
  LParams: TStringList;
  LQuery: TFDQuery;
  I: Integer;
begin
  if not Assigned(AData) or (AData.Count = 0) then
    raise Exception.Create('Objeto JSON para insercao nao pode estar vazio');

  LFields := TStringList.Create;
  LParams := TStringList.Create;
  LQuery := TFDQuery.Create(nil);
  try
    for I := 0 to AData.Count - 1 do
    begin
      LFields.Add(AData.Pairs[I].JsonString.Value);
      LParams.Add(':p' + I.ToString);
    end;

    LQuery.Connection := AConnection;
    LQuery.SQL.Text := Format(
      'insert into %s (%s) values (%s) returning %s',
      [ATableName, LFields.CommaText, LParams.CommaText, AReturningField]
    );

    for I := 0 to AData.Count - 1 do
    begin
      // default defensivo para evitar parametro com tipo desconhecido no PG
      if LQuery.Params[I].DataType = ftUnknown then
        LQuery.Params[I].DataType := ftString;
      AssignParamFromJson(LQuery.Params[I], AData.Pairs[I].JsonValue, AData.Pairs[I].JsonString.Value);
    end;

    LQuery.Open;
    Result := LQuery.Fields[0].Value;
  finally
    LQuery.Free;
    LParams.Free;
    LFields.Free;
  end;
end;

class function TWorbyRepRestDatabase.ExecuteQuery(const ASql: string; const AParams: array of Variant): TFDQuery;
var
  I: Integer;
begin
  Result := TFDQuery.Create(nil);
  try
    Result.Connection := GetConnection;
    Result.SQL.Text := ASql;
    for I := 0 to High(AParams) do
      Result.Params[I].Value := AParams[I];
    Result.Open;
  except
    Result.Free;
    raise;
  end;
end;

class function TWorbyRepRestDatabase.FieldValueToJson(AField: TField): TJSONValue;
begin
  if AField.IsNull then
    Exit(TJSONNull.Create);

  case AField.DataType of
    ftSmallint, ftInteger, ftWord, ftLongWord, ftShortint, ftByte, ftLargeint, ftAutoInc:
      Result := TJSONNumber.Create(AField.AsLargeInt);
    ftFloat, ftCurrency, ftBCD, ftFMTBcd, ftSingle, ftExtended:
      Result := TJSONNumber.Create(AField.AsFloat);
    ftBoolean:
      if AField.AsBoolean then
        Result := TJSONTrue.Create
      else
        Result := TJSONFalse.Create;
    ftDate, ftTime, ftDateTime, ftTimeStamp:
      Result := TJSONString.Create(FormatDateTime('yyyy-mm-dd hh:nn:ss', AField.AsDateTime));
  else
    Result := TJSONString.Create(AField.AsString);
  end;
end;

class function TWorbyRepRestDatabase.ParseApiDate(const AValue: string; const ADefault: TDateTime): TDateTime;
var
  LText: string;
  LFS: TFormatSettings;
begin
  LText := Trim(AValue);
  if LText = '' then
    Exit(DateOf(ADefault));

  LFS := TFormatSettings.Invariant;
  LFS.DateSeparator := '-';
  LFS.ShortDateFormat := 'yyyy-mm-dd';
  LFS.TimeSeparator := ':';
  LFS.LongTimeFormat := 'hh:nn:ss';

  if TryStrToDate(Copy(LText, 1, 10), Result, LFS) then
    Exit(DateOf(Result));
  if TryISO8601ToDate(LText, Result, False) then
    Exit(DateOf(Result));
  if TryStrToDate(LText, Result) then
    Exit(DateOf(Result));

  Result := DateOf(ADefault);
end;

class function TWorbyRepRestDatabase.ParseApiDateTime(const AValue: string; const ADefault: TDateTime): TDateTime;
var
  LText: string;
  LFS: TFormatSettings;
begin
  LText := Trim(AValue);
  if LText = '' then
    Exit(ADefault);

  LFS := TFormatSettings.Invariant;
  LFS.DateSeparator := '-';
  LFS.ShortDateFormat := 'yyyy-mm-dd';
  LFS.TimeSeparator := ':';
  LFS.LongTimeFormat := 'hh:nn:ss';

  if TryStrToDateTime(LText, Result, LFS) then
    Exit;
  if TryISO8601ToDate(LText, Result, False) then
    Exit;
  if TryStrToDateTime(LText, Result) then
    Exit;

  Result := ADefault;
end;

class function TWorbyRepRestDatabase.EncodeUrlParam(const AValue: string): string;
var
  LBytes: TBytes;
  LByte: Byte;
begin
  Result := '';
  LBytes := TEncoding.UTF8.GetBytes(AValue);
  for LByte in LBytes do
  begin
    if Char(LByte) in ['A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.', '~'] then
      Result := Result + Char(LByte)
    else if LByte = Ord(' ') then
      Result := Result + '%20'
    else
      Result := Result + '%' + IntToHex(LByte, 2);
  end;
end;

class function TWorbyRepRestDatabase.ExpandSiglasEndereco(const AEndereco: string): string;
begin
  Result := ' ' + Trim(AEndereco) + ' ';
  Result := StringReplace(Result, ' R ', ' Rua ', [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(Result, ' R. ', ' Rua ', [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(Result, ' AV ', ' Avenida ', [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(Result, ' AV. ', ' Avenida ', [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(Result, ' ROD ', ' Rodovia ', [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(Result, ' ROD. ', ' Rodovia ', [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(Result, ' EST ', ' Estrada ', [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(Result, ' EST. ', ' Estrada ', [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(Result, ' TV ', ' Travessa ', [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(Result, ' TV. ', ' Travessa ', [rfReplaceAll, rfIgnoreCase]);
  Result := Trim(Result);
end;

class function TWorbyRepRestDatabase.GeocodeAddress(const AEndereco: TEnderecoGeocode;
  out ALatitude, ALongitude: string): Boolean;

  function NomeEstado(const AUF: string): string;
  var
    LUF: string;
  begin
    LUF := UpperCase(Trim(AUF));
    if LUF = 'AC' then Result := 'Acre'
    else if LUF = 'AL' then Result := 'Alagoas'
    else if LUF = 'AP' then Result := 'Amapa'
    else if LUF = 'AM' then Result := 'Amazonas'
    else if LUF = 'BA' then Result := 'Bahia'
    else if LUF = 'CE' then Result := 'Ceara'
    else if LUF = 'DF' then Result := 'Distrito Federal'
    else if LUF = 'ES' then Result := 'Espirito Santo'
    else if LUF = 'GO' then Result := 'Goias'
    else if LUF = 'MA' then Result := 'Maranhao'
    else if LUF = 'MT' then Result := 'Mato Grosso'
    else if LUF = 'MS' then Result := 'Mato Grosso do Sul'
    else if LUF = 'MG' then Result := 'Minas Gerais'
    else if LUF = 'PA' then Result := 'Para'
    else if LUF = 'PB' then Result := 'Paraiba'
    else if LUF = 'PR' then Result := 'Parana'
    else if LUF = 'PE' then Result := 'Pernambuco'
    else if LUF = 'PI' then Result := 'Piaui'
    else if LUF = 'RJ' then Result := 'Rio de Janeiro'
    else if LUF = 'RN' then Result := 'Rio Grande do Norte'
    else if LUF = 'RS' then Result := 'Rio Grande do Sul'
    else if LUF = 'RO' then Result := 'Rondonia'
    else if LUF = 'RR' then Result := 'Roraima'
    else if LUF = 'SC' then Result := 'Santa Catarina'
    else if LUF = 'SP' then Result := 'Sao Paulo'
    else if LUF = 'SE' then Result := 'Sergipe'
    else if LUF = 'TO' then Result := 'Tocantins'
    else Result := Trim(AUF);
  end;

  function ResolveApiKey(const AEnvVar, AIniKey, ADefault: string): string;
  var
    LIni: TIniFile;
    LConfigPath: string;
  begin
    Result := Trim(GetEnvironmentVariable(AEnvVar));
    if Result <> '' then
      Exit;
    LConfigPath := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'servidor.ini';
    if FileExists(LConfigPath) then
    begin
      LIni := TIniFile.Create(LConfigPath);
      try
        Result := Trim(LIni.ReadString('config', AIniKey, ''));
      finally
        LIni.Free;
      end;
    end;
    if Result = '' then
      Result := Trim(ADefault);
  end;

  function ValorJson(AObj: TJSONObject; const ANome: string): string;
  var
    LValue: TJSONValue;
  begin
    Result := '';
    if AObj = nil then
      Exit;
    LValue := AObj.GetValue(ANome);
    if LValue <> nil then
      Result := Trim(LValue.Value);
  end;

  function ObjetoJson(AObj: TJSONObject; const ANome: string): TJSONObject;
  var
    LValue: TJSONValue;
  begin
    Result := nil;
    if AObj = nil then
      Exit;
    LValue := AObj.GetValue(ANome);
    if (LValue <> nil) and (LValue is TJSONObject) then
      Result := TJSONObject(LValue);
  end;

  function NormalizarNumeroImovel(const AValor: string): string;
  var
    I: Integer;
    C: Char;
  begin
    Result := '';
    for I := 1 to Length(AValor) do
    begin
      C := UpCase(AValor[I]);
      if C in ['A'..'Z', '0'..'9'] then
        Result := Result + C;
    end;
  end;

  function NumeroImovelConfere(const ARetornado: string): Boolean;
  begin
    Result := (NormalizarNumeroImovel(AEndereco.Numero) <> '') and
      (NormalizarNumeroImovel(ARetornado) =
       NormalizarNumeroImovel(AEndereco.Numero));
  end;

  function NumeroJsonPositivo(const AValor: string): Boolean;
  var
    I: Integer;
  begin
    Result := False;
    for I := 1 to Length(AValor) do
      if AValor[I] in ['1'..'9'] then
      begin
        Result := True;
        Exit;
      end;
  end;

  function HttpJsonGet(const AUrl: string; const AUserAgent: string): TJSONValue;
  var
    LHttp: THTTPClient;
    LResponse: IHTTPResponse;
  begin
    Result := nil;
    LHttp := THTTPClient.Create;
    try
      LHttp.ConnectionTimeout := 1500;
      LHttp.ResponseTimeout := 3000;
      LHttp.CustomHeaders['Accept'] := 'application/json';
      if AUserAgent <> '' then
        LHttp.CustomHeaders['User-Agent'] := AUserAgent;
      LResponse := LHttp.Get(AUrl);
      if (LResponse.StatusCode < 200) or (LResponse.StatusCode >= 300) then
        Exit;
      Result := TJSONObject.ParseJSONValue(LResponse.ContentAsString(TEncoding.UTF8));
    finally
      LHttp.Free;
    end;
  end;

  function ConsultarGeoapify(out ALat, ALng: string): Boolean;
  var
    LApiKey: string;
    LUrl: string;
    LJsonValue: TJSONValue;
    LRoot, LItem, LRankObj: TJSONObject;
    LResults: TJSONValue;
    LArr: TJSONArray;
  begin
    Result := False;
    ALat := '';
    ALng := '';

    LApiKey := ResolveApiKey('GEOAPIFY_API_KEY', 'geoapify_api_key', CGeoapifyKey);
    if (LApiKey = '') or SameText(LApiKey, 'Your_Geoapify_API_Key') or
       SameText(LApiKey, 'YOUR_GEOAPIFY_API_KEY') then
      Exit;

    LUrl := 'https://api.geoapify.com/v1/geocode/search?' +
      'housenumber=' + EncodeUrlParam(AEndereco.Numero) +
      '&street=' + EncodeUrlParam(ExpandSiglasEndereco(AEndereco.Logradouro)) +
      '&postcode=' + EncodeUrlParam(AEndereco.CEP) +
      '&city=' + EncodeUrlParam(AEndereco.Cidade) +
      '&state=' + EncodeUrlParam(NomeEstado(AEndereco.UF)) +
      '&country=' + EncodeUrlParam('Brasil') +
      '&format=json&limit=1&lang=pt&apiKey=' + EncodeUrlParam(LApiKey);

    LJsonValue := HttpJsonGet(LUrl, '');
    if LJsonValue = nil then
      Exit;
    try
      if not (LJsonValue is TJSONObject) then
        Exit;
      LRoot := TJSONObject(LJsonValue);
      LResults := LRoot.GetValue('results');
      if (LResults = nil) or not (LResults is TJSONArray) then
        Exit;
      LArr := TJSONArray(LResults);
      if (LArr.Count = 0) or not (LArr.Items[0] is TJSONObject) then
        Exit;
      LItem := TJSONObject(LArr.Items[0]);
      LRankObj := ObjetoJson(LItem, 'rank');

      if not SameText(ValorJson(LItem, 'result_type'), 'building') then
        Exit;
      if not SameText(ValorJson(LItem, 'match_type'), 'full_match') then
        Exit;
      if not NumeroJsonPositivo(ValorJson(LRankObj,
        'confidence_building_level')) then
        Exit;
      if not NumeroImovelConfere(ValorJson(LItem, 'housenumber')) then
        Exit;

      ALat := StringReplace(ValorJson(LItem, 'lat'), ',', '.', [rfReplaceAll]);
      ALng := StringReplace(ValorJson(LItem, 'lon'), ',', '.', [rfReplaceAll]);
      Result := (ALat <> '') and (ALng <> '');
    finally
      LJsonValue.Free;
    end;
  end;

  function ConsultarLocationIQ(const AApiKey: string;
    out ALat, ALng: string): Boolean;
  var
    LUrl: string;
    LJsonValue: TJSONValue;
    LArr: TJSONArray;
    LItem, LAddressObj: TJSONObject;
  begin
    Result := False;
    ALat := '';
    ALng := '';
    if (Trim(AApiKey) = '') or SameText(AApiKey, 'Your_LocationIQ_API_Key') then
      Exit;

    LUrl := 'https://us1.locationiq.com/v1/search/structured?' +
      'key=' + EncodeUrlParam(AApiKey) +
      '&street=' + EncodeUrlParam(AEndereco.Numero + ' ' +
        ExpandSiglasEndereco(AEndereco.Logradouro)) +
      '&city=' + EncodeUrlParam(AEndereco.Cidade) +
      '&state=' + EncodeUrlParam(NomeEstado(AEndereco.UF)) +
      '&postalcode=' + EncodeUrlParam(AEndereco.CEP) +
      '&country=' + EncodeUrlParam('Brasil') +
      '&countrycodes=br&format=json&addressdetails=1' +
      '&normalizeaddress=1&limit=1&accept-language=pt-BR';

    LJsonValue := HttpJsonGet(LUrl, '');
    if LJsonValue = nil then
      Exit;
    try
      if not (LJsonValue is TJSONArray) then
        Exit;
      LArr := TJSONArray(LJsonValue);
      if (LArr.Count = 0) or not (LArr.Items[0] is TJSONObject) then
        Exit;
      LItem := TJSONObject(LArr.Items[0]);
      LAddressObj := ObjetoJson(LItem, 'address');
      if not NumeroImovelConfere(ValorJson(LAddressObj, 'house_number')) then
        Exit;

      ALat := StringReplace(ValorJson(LItem, 'lat'), ',', '.', [rfReplaceAll]);
      ALng := StringReplace(ValorJson(LItem, 'lon'), ',', '.', [rfReplaceAll]);
      Result := (ALat <> '') and (ALng <> '');
    finally
      LJsonValue.Free;
    end;
  end;

  function ConsultarNominatim(out ALat, ALng: string): Boolean;
  var
    LUrl: string;
    LJsonValue: TJSONValue;
    LArr: TJSONArray;
    LItem, LAddressObj: TJSONObject;
  begin
    Result := False;
    ALat := '';
    ALng := '';

    LUrl := 'https://nominatim.openstreetmap.org/search?' +
      'street=' + EncodeUrlParam(AEndereco.Numero + ' ' +
        ExpandSiglasEndereco(AEndereco.Logradouro)) +
      '&city=' + EncodeUrlParam(AEndereco.Cidade) +
      '&state=' + EncodeUrlParam(NomeEstado(AEndereco.UF)) +
      '&postalcode=' + EncodeUrlParam(AEndereco.CEP) +
      '&country=' + EncodeUrlParam('Brasil') +
      '&format=jsonv2&addressdetails=1&limit=1&countrycodes=br';

    Sleep(1100);
    LJsonValue := HttpJsonGet(LUrl,
      'WorbyRepRest/1.0 (geocodificacao de clientes)');
    if LJsonValue = nil then
      Exit;
    try
      if not (LJsonValue is TJSONArray) then
        Exit;
      LArr := TJSONArray(LJsonValue);
      if (LArr.Count = 0) or not (LArr.Items[0] is TJSONObject) then
        Exit;
      LItem := TJSONObject(LArr.Items[0]);
      LAddressObj := ObjetoJson(LItem, 'address');
      if not NumeroImovelConfere(ValorJson(LAddressObj, 'house_number')) then
        Exit;

      ALat := StringReplace(ValorJson(LItem, 'lat'), ',', '.', [rfReplaceAll]);
      ALng := StringReplace(ValorJson(LItem, 'lon'), ',', '.', [rfReplaceAll]);
      Result := (ALat <> '') and (ALng <> '');
    finally
      LJsonValue.Free;
    end;
  end;

var
  LLocationIQKey: string;
begin
  Result := False;
  ALatitude := '';
  ALongitude := '';
  if (Trim(AEndereco.Logradouro) = '') or (Trim(AEndereco.Cidade) = '') or
     (Trim(AEndereco.Numero) = '') then
    Exit;

  if ConsultarGeoapify(ALatitude, ALongitude) then
  begin
    Result := True;
    Exit;
  end;

  LLocationIQKey := ResolveApiKey('LOCATIONIQ_API_KEY', 'locationiq_api_key', CLocationIQKey);
  if ConsultarLocationIQ(LLocationIQKey, ALatitude, ALongitude) then
  begin
    Result := True;
    Exit;
  end;

  Result := ConsultarNominatim(ALatitude, ALongitude);
end;

class function TWorbyRepRestDatabase.GetClienteEnderecoGeocode(ACodCliente: Int64): TEnderecoGeocode;
var
  LQuery: TFDQuery;
begin
  Result := Default(TEnderecoGeocode);
  LQuery := ExecuteQuery(
    'select c.endereco, c.nr_endereco, c.bairro, c.cep, cd.nom_cidade, cd.uf ' +
    'from cliente c ' +
    'left join cidades cd on cd.cod_cidade = c.cod_cidade ' +
    'where c.cod_cliente = :p0',
    [ACodCliente]
  );
  try
    if LQuery.IsEmpty then
      Exit;

    Result.Logradouro := Trim(LQuery.FieldByName('endereco').AsString);
    Result.Numero := Trim(LQuery.FieldByName('nr_endereco').AsString);
    Result.Bairro := Trim(LQuery.FieldByName('bairro').AsString);
    Result.Cidade := Trim(LQuery.FieldByName('nom_cidade').AsString);
    Result.UF := Trim(LQuery.FieldByName('uf').AsString);
    Result.CEP := Trim(LQuery.FieldByName('cep').AsString);
  finally
    LQuery.Free;
  end;
end;

class procedure TWorbyRepRestDatabase.SetJsonString(AObject: TJSONObject; const AName, AValue: string);
var
  LPair: TJSONPair;
begin
  if not Assigned(AObject) then
    Exit;

  LPair := AObject.RemovePair(AName);
  LPair.Free;
  AObject.AddPair(AName, AValue);
end;

class procedure TWorbyRepRestDatabase.PreencherGeolocalizacaoClientes(AClientes: TJSONArray);
var
  I: Integer;
  LObj: TJSONObject;
  LCodCliente: Int64;
  LLatitude: string;
  LLongitude: string;
  LLatitudeFloat: Double;
  LLongitudeFloat: Double;
  LEndereco: TEnderecoGeocode;
  LQuery: TFDQuery;
  LFS: TFormatSettings;
  LTotalClientes, LProcessados, LGeocodificados: Integer;
begin
  if not Assigned(AClientes) then
    Exit;

  LFS := TFormatSettings.Invariant;
  LFS.DecimalSeparator := '.';
  LTotalClientes := AClientes.Count;
  LProcessados := 0;
  LGeocodificados := 0;
  LogSyncAuditError('Geocodificacao iniciada | total=' + LTotalClientes.ToString);
  for I := 0 to AClientes.Count - 1 do
  begin
    Inc(LProcessados);
    if (LProcessados mod 25 = 0) or (LProcessados = LTotalClientes) then
      LogSyncAuditError('Geocodificacao progresso | ' + LProcessados.ToString + ' de ' + LTotalClientes.ToString +
        ' (' + Round(LProcessados / Max(1, LTotalClientes) * 100).ToString + '%) | atualizados=' + LGeocodificados.ToString);
    if not (AClientes.Items[I] is TJSONObject) then
      Continue;

    LObj := TJSONObject(AClientes.Items[I]);
    LLatitude := Trim(LObj.GetValue<string>('latitude', ''));
    LLongitude := Trim(LObj.GetValue<string>('longitude', ''));
    if (LLatitude <> '') and (LLongitude <> '') then
      Continue;

    LCodCliente := LObj.GetValue<Int64>('cod_cliente', 0);
    if LCodCliente <= 0 then
      Continue;

    try
      LEndereco := GetClienteEnderecoGeocode(LCodCliente);
      if not GeocodeAddress(LEndereco, LLatitude, LLongitude) then
        Continue;
      if not TryStrToFloat(StringReplace(LLatitude, ',', '.', [rfReplaceAll]), LLatitudeFloat, LFS) then
        Continue;
      if not TryStrToFloat(StringReplace(LLongitude, ',', '.', [rfReplaceAll]), LLongitudeFloat, LFS) then
        Continue;

      LQuery := TFDQuery.Create(nil);
      try
        LQuery.Connection := GetConnection;
        LQuery.SQL.Text :=
          'update cliente set latitude = :latitude, longitude = :longitude ' +
          'where cod_cliente = :cod_cliente ' +
          'and (latitude is null or longitude is null)';
        LQuery.ParamByName('latitude').AsFloat := LLatitudeFloat;
        LQuery.ParamByName('longitude').AsFloat := LLongitudeFloat;
        LQuery.ParamByName('cod_cliente').AsLargeInt := LCodCliente;
        LQuery.ExecSQL;
      finally
        LQuery.Free;
      end;

      SetJsonString(LObj, 'latitude', LLatitude);
      SetJsonString(LObj, 'longitude', LLongitude);
      Inc(LGeocodificados);
    except
      // A falha de geocodificacao nao deve bloquear a listagem/sincronizacao de clientes.
    end;
  end;
  UpdateGeocodeProgress(LProcessados, LGeocodificados, LTotalClientes);
  EndGeocodeProgress;
  LogSyncAuditError('Geocodificacao concluida | processados=' + LProcessados.ToString +
    ' | atualizados=' + LGeocodificados.ToString + ' | total=' + LTotalClientes.ToString);
end;

class function TWorbyRepRestDatabase.JsonValueCI(AObject: TJSONObject;
  const AName: string): TJSONValue;
var
  LPair: TJSONPair;
begin
  Result := nil;
  if not Assigned(AObject) then
    Exit;

  Result := AObject.GetValue(AName);
  if Assigned(Result) then
    Exit;

  for LPair in AObject do
    if SameText(LPair.JsonString.Value, AName) then
      Exit(LPair.JsonValue);
end;

class function TWorbyRepRestDatabase.SqliteIdent(const AValue: string): string;
begin
  Result := '"' + StringReplace(AValue, '"', '""', [rfReplaceAll]) + '"';
end;

class function TWorbyRepRestDatabase.SqliteLiteral(AValue: TJSONValue;
  const AFieldName: string): string;
var
  LText: string;
  LBytes: TBytes;
  LHex: TStringBuilder;
  I: Integer;
const
  CHex = '0123456789ABCDEF';
begin
  if (not Assigned(AValue)) or (AValue is TJSONNull) then
    Exit('null');

  if SameText(AFieldName, 'imagem_bd') then
  begin
    LText := Trim(AValue.Value);
    if LText = '' then
      Exit('null');

    try
      LBytes := TNetEncoding.Base64.DecodeStringToBytes(LText);
    except
      LBytes := TEncoding.UTF8.GetBytes(LText);
    end;

    LHex := TStringBuilder.Create;
    try
      for I := 0 to Length(LBytes) - 1 do
      begin
        LHex.Append(CHex[(LBytes[I] shr 4) + 1]);
        LHex.Append(CHex[(LBytes[I] and $0F) + 1]);
      end;
      Exit('X''' + LHex.ToString + '''');
    finally
      LHex.Free;
    end;
  end;

  if AValue is TJSONNumber then
    Exit(TJSONNumber(AValue).Value);

  if AValue is TJSONTrue then
    Exit('1');

  if AValue is TJSONFalse then
    Exit('0');

  LText := AValue.Value;
  Result := '''' + StringReplace(LText, '''', '''''', [rfReplaceAll]) + '''';
end;

class function TWorbyRepRestDatabase.CsvLineToText(const ALine: string): string;
var
  I: Integer;
  LText: string;
begin
  Result := ALine;
  LText := ALine;
  if (Length(LText) >= 2) and (LText[1] = '"') and (LText[Length(LText)] = '"') then
  begin
    Delete(LText, Length(LText), 1);
    Delete(LText, 1, 1);
    Result := '';
    I := 1;
    while I <= Length(LText) do
    begin
      if (LText[I] = '"') and (I < Length(LText)) and (LText[I + 1] = '"') then
      begin
        Result := Result + '"';
        Inc(I, 2);
      end
      else
      begin
        Result := Result + LText[I];
        Inc(I);
      end;
    end;
  end;
end;

class function TWorbyRepRestDatabase.CopyScriptThroughPostgresFile(const AScript: string): string;
var
  LConn: TFDConnection;
  LQuery: TFDQuery;
  LLines: TStringList;
  LOutLines: TStringList;
  LDir: string;
  LFileName: string;
  LCopyFileName: string;
  LGuidText: string;
  LGuid: TGUID;
  I: Integer;

  function PgLiteral(const AValue: string): string;
  begin
    Result := '''' + StringReplace(AValue, '''', '''''', [rfReplaceAll]) + '''';
  end;

begin
  Result := AScript;
  LFileName := '';
  LConn := GetConnection;
  LLines := TStringList.Create;
  LOutLines := TStringList.Create;
  LQuery := TFDQuery.Create(nil);
  try
    LDir := TPath.Combine(ExtractFilePath(ParamStr(0)), 'sync_temp');
    TDirectory.CreateDirectory(LDir);
    CreateGUID(LGuid);
    LGuidText := GUIDToString(LGuid);
    LGuidText := StringReplace(LGuidText, '-', '', [rfReplaceAll]);
    LGuidText := StringReplace(LGuidText, '{', '', [rfReplaceAll]);
    LGuidText := StringReplace(LGuidText, '}', '', [rfReplaceAll]);
    LFileName := TPath.Combine(LDir,
      'sync_' + LGuidText + '.sqlcsv');
    LCopyFileName := StringReplace(LFileName, '\', '/', [rfReplaceAll]);

    LLines.Text := AScript;
    LQuery.Connection := LConn;
    LConn.ExecSQL('drop table if exists pg_temp.worby_sync_script');
    LConn.ExecSQL('create temp table worby_sync_script (ord integer not null, line text not null)');

    LQuery.SQL.Text := 'insert into pg_temp.worby_sync_script (ord, line) values (:ord, :line)';
    for I := 0 to LLines.Count - 1 do
    begin
      LQuery.ParamByName('ord').AsInteger := I;
      LQuery.ParamByName('line').AsString := LLines[I];
      LQuery.ExecSQL;
    end;

    LConn.ExecSQL(
      'copy (select line from pg_temp.worby_sync_script order by ord) to ' +
      PgLiteral(LCopyFileName) +
      ' with (format csv, header false, quote ''"'', escape ''"'')'
    );

    LOutLines.LoadFromFile(LFileName, TEncoding.UTF8);
    for I := 0 to LOutLines.Count - 1 do
      LOutLines[I] := CsvLineToText(LOutLines[I]);
    Result := LOutLines.Text;
  finally
    try
      if LFileName <> '' then
        TFile.Delete(LFileName);
    except
    end;
    try
      LConn.ExecSQL('drop table if exists pg_temp.worby_sync_script');
    except
    end;
    LQuery.Free;
    LOutLines.Free;
    LLines.Free;
  end;
end;

class function TWorbyRepRestDatabase.BuildSyncScript(const ACodRepresentante: string;
  ATables: TJSONArray; ASchema: TJSONObject; ADataUltSincronizacao: TJSONObject;
  const AVersao: string): TJSONObject;
var
  LScript: TStringBuilder;
  LStats: TJSONArray;
  LTableValue: TJSONValue;
  LTableName: string;
  LTable: TTableInfo;
  LRows: TJSONArray;
  LRowValue: TJSONValue;
  LRowObj: TJSONObject;
  LColumnsValue: TJSONValue;
  LColumns: TJSONArray;
  LColumnValue: TJSONValue;
  LColumnName: string;
  LColsSql: TStringBuilder;
  LValsSql: TStringBuilder;
  LDataUlt: string;
  LNumDocsCsv: string;
  LNumDocValue: TJSONValue;
  LNumDocInt: Int64;
  LStat: TJSONObject;
  LScriptText: string;
  LScriptSource: string;
  LPageRows: TJSONArray;
  LPageSize: Integer;
  LOffset: Integer;
  I: Integer;
  J: Integer;
  K: Integer;

  procedure AddLine(const ALine: string);
  begin
    LScript.Append(ALine).Append(sLineBreak);
  end;

  function LoadRowsForScript: TJSONArray;
  var
    LPageIndex: Integer;
  begin
    if SameText(LTableName, 'cliente') then
    begin
      Result := TJSONArray.Create;
      LPageSize := CMaxClienteSyncPageSize;
      LOffset := 0;
      repeat
        LPageRows := ListTable(LTable, LPageSize, LOffset, ACodRepresentante, LDataUlt);
        try
          for LPageIndex := 0 to LPageRows.Count - 1 do
            Result.AddElement(LPageRows.Items[LPageIndex].Clone as TJSONValue);

          if LPageRows.Count < LPageSize then
            Break;

          Inc(LOffset, LPageSize);
        finally
          LPageRows.Free;
        end;
      until False;
      Exit;
    end;

    if SameText(LTableName, 'vendas2') and (LNumDocsCsv <> '') then
      Result := ListTable(LTable, 0, 0, ACodRepresentante, '', LNumDocsCsv)
    else
      Result := ListTable(LTable, 0, 0, ACodRepresentante, LDataUlt);
  end;

begin
  LScript := TStringBuilder.Create;
  LStats := TJSONArray.Create;
  try
    AddLine('begin transaction;');
    LNumDocsCsv := '';

    for I := 0 to ATables.Count - 1 do
    begin
      LTableValue := ATables.Items[I];
      LTableName := Trim(LTableValue.Value);
      if LTableName = '' then
        Continue;

      if not TWorbyRepRestMetadata.TryGetTable(LTableName, LTable) then
        raise Exception.Create('Tabela nao mapeada: ' + LTableName);

      LColumnsValue := nil;
      if Assigned(ASchema) then
        LColumnsValue := ASchema.GetValue(LTableName);
      if not (LColumnsValue is TJSONArray) then
        raise Exception.Create('Schema nao informado para tabela: ' + LTableName);
      LColumns := TJSONArray(LColumnsValue);
      if LColumns.Count = 0 then
        Continue;

      LDataUlt := '';
      if False and Assigned(ADataUltSincronizacao) and
         (SameText(LTableName, 'produto') or SameText(LTableName, 'subcategoria')) and
         Assigned(ADataUltSincronizacao.GetValue(LTableName)) then
        LDataUlt := Trim(ADataUltSincronizacao.GetValue(LTableName).Value);

      LRows := LoadRowsForScript;
      try
        AddLine('delete from ' + SqliteIdent(LTableName) + ';');

        for J := 0 to LRows.Count - 1 do
        begin
          LRowValue := LRows.Items[J];
          if not (LRowValue is TJSONObject) then
            Continue;
          LRowObj := TJSONObject(LRowValue);

          if SameText(LTableName, 'vendas1') then
          begin
            LNumDocValue := JsonValueCI(LRowObj, 'numdoc');
            if Assigned(LNumDocValue) and TryStrToInt64(Trim(LNumDocValue.Value), LNumDocInt) then
            begin
              if LNumDocsCsv <> '' then
                LNumDocsCsv := LNumDocsCsv + ',';
              LNumDocsCsv := LNumDocsCsv + IntToStr(LNumDocInt);
            end;
          end;

          LColsSql := TStringBuilder.Create;
          LValsSql := TStringBuilder.Create;
          try
            for K := 0 to LColumns.Count - 1 do
            begin
              LColumnValue := LColumns.Items[K];
              LColumnName := Trim(LColumnValue.Value);
              if LColumnName = '' then
                Continue;

              if LColsSql.Length > 0 then
              begin
                LColsSql.Append(', ');
                LValsSql.Append(', ');
              end;
              LColsSql.Append(SqliteIdent(LColumnName));
              if SameText(LTableName, 'produto') and SameText(LColumnName, 'desconto_maximo') and
                 Assigned(JsonValueCI(LRowObj, 'desconto_maximo_app')) then
                LValsSql.Append(SqliteLiteral(JsonValueCI(LRowObj, 'desconto_maximo_app'), LColumnName))
              else
                LValsSql.Append(SqliteLiteral(JsonValueCI(LRowObj, LColumnName), LColumnName));
            end;

            if LColsSql.Length > 0 then
              AddLine('insert or replace into ' + SqliteIdent(LTableName) +
                ' (' + LColsSql.ToString + ') values (' + LValsSql.ToString + ');');
          finally
            LValsSql.Free;
            LColsSql.Free;
          end;
        end;

        AddLine(
          'insert into sync_table_state (table_name, representative_code, last_sync_at, row_count, last_error) values (' +
          '''' + StringReplace(LTableName, '''', '''''', [rfReplaceAll]) + ''', ' +
          '''' + StringReplace(ACodRepresentante, '''', '''''', [rfReplaceAll]) + ''', datetime(''now''), ' +
          LRows.Count.ToString + ', null) ' +
          'on conflict(table_name) do update set representative_code = excluded.representative_code, ' +
          'last_sync_at = excluded.last_sync_at, row_count = excluded.row_count, last_error = null;'
        );

        LStat := TJSONObject.Create;
        LStat.AddPair('table', LTableName);
        LStat.AddPair('rows', TJSONNumber.Create(LRows.Count));
        LStats.AddElement(LStat);
      finally
        LRows.Free;
      end;
    end;

    AddLine('commit;');

    LScriptText := LScript.ToString;
    LScriptSource := 'memory';

    RegistrarSincronizacaoRepresentante(ACodRepresentante, 'BuildSyncScript', AVersao);

    Result := TJSONObject.Create;
    Result.AddPair('success', TJSONTrue.Create);
    Result.AddPair('scriptSource', LScriptSource);
    Result.AddPair('script', LScriptText);
    Result.AddPair('tables', LStats.Clone as TJSONValue);
  finally
    LStats.Free;
    LScript.Free;
  end;
end;

class function TWorbyRepRestDatabase.GetById(const ATableName, APrimaryKey: string;
  APrimaryKeyType: TTableKeyType; const AValue: string): TJSONObject;
var
  LQuery: TFDQuery;
  LArray: TJSONArray;
  LIntValue: Int64;
begin
  case APrimaryKeyType of
    tktInteger:
      begin
        if not TryStrToInt64(Trim(AValue), LIntValue) then
          raise Exception.Create('Valor de id invalido para chave numerica');

        LQuery := ExecuteQuery(
          Format('select * from %s where %s = :p0', [ATableName, APrimaryKey]),
          [LIntValue]
        );
      end;
  else
    LQuery := ExecuteQuery(
      Format('select * from %s where %s = :p0', [ATableName, APrimaryKey]),
      [AValue]
    );
  end;
  try
    LArray := QueryToJsonArray(LQuery);
    try
      if LArray.Count = 0 then
        Exit(nil);
      Result := LArray.Items[0] as TJSONObject;
      LArray.Remove(0);
    finally
      LArray.Free;
    end;
  finally
    LQuery.Free;
  end;
end;

class function TWorbyRepRestDatabase.SaveRepresentanteSqliteBackup(ABackup: TJSONObject): TJSONObject;
var
  LCodRepresentante: Integer;
  LBackupBase64: string;
  LBackupBytes: TBytes;
  LVersao: string;
  LTamanho: Int64;
  LConnection: TFDConnection;
  LQuery: TFDQuery;
  LStream: TBytesStream;
begin
  if not Assigned(ABackup) then
    raise Exception.Create('JSON de backup invalido');

  LCodRepresentante := ABackup.GetValue<Integer>('cod_representante', 0);
  if LCodRepresentante <= 0 then
    raise Exception.Create('cod_representante invalido');
  if not Assigned(JsonValueCI(ABackup, 'backup_base64')) then
    raise Exception.Create('backup_base64 obrigatorio');
  LBackupBase64 := JsonValueCI(ABackup, 'backup_base64').Value;
  if Trim(LBackupBase64) = '' then
    raise Exception.Create('backup_base64 obrigatorio');

  LBackupBytes := TNetEncoding.Base64.DecodeStringToBytes(LBackupBase64);
  if Length(LBackupBytes) = 0 then
    raise Exception.Create('backup vazio');

  LVersao := Copy(ABackup.GetValue<string>('versao', ''), 1, 30);
  LTamanho := ABackup.GetValue<Int64>('tamanho', 0);

  EnsureRepresentanteSqliteBackupColumns;
  LConnection := GetConnection;
  LQuery := TFDQuery.Create(nil);
  try
    LQuery.Connection := LConnection;
    LQuery.SQL.Text :=
      'update public.representante set ' +
      'backup_sqlite = :backup_sqlite, ' +
      'backup_sqlite_datahora = now(), ' +
      'backup_sqlite_versao = :backup_sqlite_versao, ' +
      'backup_sqlite_tamanho = :backup_sqlite_tamanho ' +
      'where id = :id';
    LQuery.ParamByName('backup_sqlite').DataType := ftBlob;
    LStream := TBytesStream.Create(LBackupBytes);
    try
      LQuery.ParamByName('backup_sqlite').LoadFromStream(LStream, ftBlob);
    finally
      LStream.Free;
    end;
    LQuery.ParamByName('backup_sqlite_versao').AsString := LVersao;
    LQuery.ParamByName('backup_sqlite_tamanho').AsLargeInt := LTamanho;
    LQuery.ParamByName('id').AsInteger := LCodRepresentante;
    LQuery.ExecSQL;

    if LQuery.RowsAffected = 0 then
      raise Exception.Create('representante nao encontrado');
  finally
    LQuery.Free;
  end;

  Result := TJSONObject.Create;
  Result.AddPair('ok', TJSONTrue.Create);
  Result.AddPair('cod_representante', TJSONNumber.Create(LCodRepresentante));
  Result.AddPair('compressed_bytes', TJSONNumber.Create(Length(LBackupBytes)));
  Result.AddPair('tamanho', TJSONNumber.Create(LTamanho));
end;

class function TWorbyRepRestDatabase.GetRepresentanteSqliteBackup(ACodRepresentante: Integer): TJSONObject;
var
  LConnection: TFDConnection;
  LQuery: TFDQuery;
  LBytes: TBytes;
  LStream: TBytesStream;
begin
  if ACodRepresentante <= 0 then
    raise Exception.Create('cod_representante invalido');

  EnsureRepresentanteSqliteBackupColumns;
  LConnection := GetConnection;
  LQuery := TFDQuery.Create(nil);
  try
    LQuery.Connection := LConnection;
    LQuery.SQL.Text :=
      'select backup_sqlite, backup_sqlite_datahora, backup_sqlite_versao, backup_sqlite_tamanho ' +
      'from public.representante where id = :id';
    LQuery.ParamByName('id').AsInteger := ACodRepresentante;
    LQuery.Open;

    Result := TJSONObject.Create;
    if LQuery.IsEmpty then
    begin
      Result.AddPair('ok', TJSONFalse.Create);
      Result.AddPair('message', 'representante nao encontrado');
      Exit;
    end;

    if LQuery.FieldByName('backup_sqlite').IsNull then
    begin
      Result.AddPair('ok', TJSONFalse.Create);
      Result.AddPair('message', 'backup nao encontrado');
      Exit;
    end;

    LStream := TBytesStream.Create;
    try
      TBlobField(LQuery.FieldByName('backup_sqlite')).SaveToStream(LStream);
      SetLength(LBytes, LStream.Size);
      if LStream.Size > 0 then
        Move(LStream.Bytes[0], LBytes[0], LStream.Size);
    finally
      LStream.Free;
    end;
    if Length(LBytes) = 0 then
    begin
      Result.AddPair('ok', TJSONFalse.Create);
      Result.AddPair('message', 'backup vazio');
      Exit;
    end;

    Result.AddPair('ok', TJSONTrue.Create);
    Result.AddPair('cod_representante', TJSONNumber.Create(ACodRepresentante));
    Result.AddPair('backup_base64', TNetEncoding.Base64.EncodeBytesToString(LBytes));
    Result.AddPair('compressed_bytes', TJSONNumber.Create(Length(LBytes)));
    Result.AddPair('tamanho', TJSONNumber.Create(LQuery.FieldByName('backup_sqlite_tamanho').AsLargeInt));
    Result.AddPair('versao', LQuery.FieldByName('backup_sqlite_versao').AsString);
    Result.AddPair('datahora', FormatDateTime('yyyy-mm-dd hh:nn:ss', LQuery.FieldByName('backup_sqlite_datahora').AsDateTime));
  finally
    LQuery.Free;
  end;
end;
class function TWorbyRepRestDatabase.InsertPedido(AVendas1: TJSONObject;
  AVendas2: TJSONArray): TJSONObject;
var
  LConnection: TFDConnection;
  I: Integer;
  LItem: TJSONValue;
  LVendas1Insert: TJSONObject;
  LVendas2Item: TJSONObject;
  LNumDoc: Variant;
  LNumDocInt: Int64;
  LTotBruto: Double;
  LTotLiquido: Double;

  function JsonFloat(AObj: TJSONObject; const AName: string): Double;
  var
    LVal: TJSONValue;
    LFS: TFormatSettings;
  begin
    Result := 0;
    if not Assigned(AObj) then
      Exit;
    LVal := AObj.GetValue(AName);
    if not Assigned(LVal) or (LVal is TJSONNull) then
      Exit;
    LFS := TFormatSettings.Create;
    LFS.DecimalSeparator := '.';
    Result := StrToFloatDef(StringReplace(Trim(LVal.Value), ',', '.', [rfReplaceAll]), 0, LFS);
  end;

  procedure SetJsonNumber(AObj: TJSONObject; const AName: string; const AValue: Double);
  var
    LPair: TJSONPair;
  begin
    if not Assigned(AObj) then
      Exit;
    LPair := AObj.RemovePair(AName);
    if Assigned(LPair) then
      LPair.Free;
    AObj.AddPair(AName, TJSONNumber.Create(AValue));
  end;

  procedure NormalizarTotaisPedido;
  var
    J: Integer;
    LObj: TJSONObject;
    LQtd: Double;
    LVolume: Double;
    LPreco: Double;
    LPrecoBruto: Double;
    LSubTotal: Double;
    LSubTotalBruto: Double;
  begin
    LTotBruto := 0;
    LTotLiquido := 0;

    for J := 0 to AVendas2.Count - 1 do
    begin
      if not (AVendas2.Items[J] is TJSONObject) then
        Continue;

      LObj := TJSONObject(AVendas2.Items[J]);
      LQtd := JsonFloat(LObj, 'qtd');
      LVolume := JsonFloat(LObj, 'volume');
      LPreco := JsonFloat(LObj, 'preco');
      LPrecoBruto := JsonFloat(LObj, 'preco_bruto');
      LSubTotal := JsonFloat(LObj, 'sub_total');
      LSubTotalBruto := JsonFloat(LObj, 'sub_total_bruto');

      if (LVolume = 0) and (LQtd <> 0) then
      begin
        LVolume := LQtd;
        SetJsonNumber(LObj, 'volume', LVolume);
      end;

      if LPrecoBruto = 0 then
      begin
        LPrecoBruto := LPreco;
        if LPrecoBruto <> 0 then
          SetJsonNumber(LObj, 'preco_bruto', LPrecoBruto);
      end;

      if (LSubTotal = 0) and (LPreco <> 0) and (LQtd <> 0) then
      begin
        LSubTotal := LPreco * LQtd;
        SetJsonNumber(LObj, 'sub_total', LSubTotal);
      end;

      if (LSubTotalBruto = 0) and (LPrecoBruto <> 0) and (LQtd <> 0) then
      begin
        LSubTotalBruto := LPrecoBruto * LQtd;
        SetJsonNumber(LObj, 'sub_total_bruto', LSubTotalBruto);
      end;

      LTotLiquido := LTotLiquido + LSubTotal;
      LTotBruto := LTotBruto + LSubTotalBruto;
    end;

    if (LTotBruto = 0) and (LTotLiquido <> 0) then
      LTotBruto := LTotLiquido;

    if LTotBruto <> 0 then
      SetJsonNumber(AVendas1, 'tot_bruto', LTotBruto);
    if (JsonFloat(AVendas1, 'tot_liquido') = 0) and (LTotLiquido <> 0) then
      SetJsonNumber(AVendas1, 'tot_liquido', LTotLiquido);
    if (JsonFloat(AVendas1, 'tot_liquido_ant') = 0) and (LTotLiquido <> 0) then
      SetJsonNumber(AVendas1, 'tot_liquido_ant', LTotLiquido);
  end;

begin
  if not Assigned(AVendas1) then
    raise Exception.Create('Objeto vendas1 e obrigatorio');

  if not Assigned(AVendas2) then
    raise Exception.Create('Array vendas2 e obrigatorio');

  NormalizarTotaisPedido;

  LConnection := GetConnection;
  if not LConnection.InTransaction then
    LConnection.StartTransaction;

  try
    LVendas1Insert := CloneJsonObject(AVendas1);
    try
      if Assigned(LVendas1Insert.GetValue('numdoc')) then
        LVendas1Insert.RemovePair('numdoc').Free;

      LNumDoc := ExecuteInsertObjectReturning(LConnection, 'vendas1', LVendas1Insert, 'numdoc');
      LNumDocInt := VarAsType(LNumDoc, varInt64);
    finally
      LVendas1Insert.Free;
    end;

    for I := 0 to AVendas2.Count - 1 do
    begin
      LItem := AVendas2.Items[I];
      if not (LItem is TJSONObject) then
        raise Exception.Create('Cada item de vendas2 deve ser um objeto JSON');

      LVendas2Item := CloneJsonObject(TJSONObject(LItem));
      try
        if Assigned(LVendas2Item.GetValue('numdoc')) then
          LVendas2Item.RemovePair('numdoc').Free;
        LVendas2Item.AddPair('numdoc', TJSONNumber.Create(LNumDocInt));

        ExecuteInsertObject(LConnection, 'vendas2', LVendas2Item);
      finally
        LVendas2Item.Free;
      end;
    end;

    LConnection.Commit;

    Result := TJSONObject.Create;
    Result.AddPair('success', TJSONTrue.Create);
    Result.AddPair('vendas1Inserido', TJSONTrue.Create);
    Result.AddPair('itensInseridos', TJSONNumber.Create(AVendas2.Count));
    Result.AddPair('numdoc', TJSONNumber.Create(LNumDocInt));
  except
    if LConnection.InTransaction then
      LConnection.Rollback;
    raise;
  end;
end;

class function TWorbyRepRestDatabase.InsertPedidosDigitados(APedidos: TJSONArray;
  const ACodRepresentante: string): TJSONObject;
var
  I: Integer;
  LPedidoValue: TJSONValue;
  LPedidoObj: TJSONObject;
  LVendas1Value: TJSONValue;
  LVendas1Obj: TJSONObject;
  LVendas2Value: TJSONValue;
  LRetPedido: TJSONObject;
  LResultadoItem: TJSONObject;
  LResultados: TJSONArray;
  LPedidoIdLocal: string;
  LInseridos: Integer;
  LErros: Integer;
  LNumDocValue: TJSONValue;
  LItensValue: TJSONValue;
  LCodRepresentanteGlobal: Integer;
  LCodRepresentantePedido: Integer;
begin
  if not Assigned(APedidos) then
    raise Exception.Create('Array pedidos e obrigatorio');

  LResultados := TJSONArray.Create;
  try
    LInseridos := 0;
    LErros := 0;
    LCodRepresentanteGlobal := StrToIntDef(Trim(ACodRepresentante), 0);

    for I := 0 to APedidos.Count - 1 do
    begin
      LPedidoValue := APedidos.Items[I];
      LResultadoItem := TJSONObject.Create;
      LResultados.AddElement(LResultadoItem);

      if not (LPedidoValue is TJSONObject) then
      begin
        Inc(LErros);
        LResultadoItem.AddPair('success', TJSONFalse.Create);
        LResultadoItem.AddPair('index', TJSONNumber.Create(I));
        LResultadoItem.AddPair('error', 'Pedido deve ser objeto JSON');
        Continue;
      end;

      LPedidoObj := TJSONObject(LPedidoValue);
      LPedidoIdLocal := LPedidoObj.GetValue<string>('pedido_id', '');
      if LPedidoIdLocal = '' then
        LPedidoIdLocal := LPedidoObj.GetValue<string>('pedidoId', '');
      if LPedidoIdLocal = '' then
        LPedidoIdLocal := LPedidoObj.GetValue<string>('id', '');

      if LPedidoIdLocal <> '' then
        LResultadoItem.AddPair('pedido_id', LPedidoIdLocal);
      LResultadoItem.AddPair('index', TJSONNumber.Create(I));

      LVendas1Value := LPedidoObj.GetValue('vendas1');
      LVendas2Value := LPedidoObj.GetValue('vendas2');
      if not (LVendas1Value is TJSONObject) then
      begin
        Inc(LErros);
        LResultadoItem.AddPair('success', TJSONFalse.Create);
        LResultadoItem.AddPair('error', 'Campo vendas1 deve ser um objeto JSON');
        Continue;
      end;
      if not (LVendas2Value is TJSONArray) then
      begin
        Inc(LErros);
        LResultadoItem.AddPair('success', TJSONFalse.Create);
        LResultadoItem.AddPair('error', 'Campo vendas2 deve ser um array JSON');
        Continue;
      end;

      LVendas1Obj := TJSONObject(LVendas1Value);
      LCodRepresentantePedido := LVendas1Obj.GetValue<Integer>('cod_representante', 0);
      if LCodRepresentantePedido <= 0 then
        LCodRepresentantePedido := LVendas1Obj.GetValue<Integer>('id_representante', 0);
      if LCodRepresentantePedido <= 0 then
        LCodRepresentantePedido := LPedidoObj.GetValue<Integer>('codRepresentante', 0);
      if LCodRepresentantePedido <= 0 then
        LCodRepresentantePedido := LPedidoObj.GetValue<Integer>('cod_representante', 0);
      if LCodRepresentantePedido <= 0 then
        LCodRepresentantePedido := LCodRepresentanteGlobal;
      if LCodRepresentantePedido > 0 then
      begin
        if Assigned(LVendas1Obj.GetValue('cod_representante')) then
          LVendas1Obj.RemovePair('cod_representante').Free;
        LVendas1Obj.AddPair('cod_representante', TJSONNumber.Create(LCodRepresentantePedido));
      end;

      try
        LRetPedido := InsertPedido(LVendas1Obj, TJSONArray(LVendas2Value));
        try
          Inc(LInseridos);
          LResultadoItem.AddPair('success', TJSONTrue.Create);
          LNumDocValue := LRetPedido.GetValue('numdoc');
          if Assigned(LNumDocValue) then
            LResultadoItem.AddPair('numdoc', LNumDocValue.Clone as TJSONValue);
          LItensValue := LRetPedido.GetValue('itensInseridos');
          if Assigned(LItensValue) then
            LResultadoItem.AddPair('itensInseridos', LItensValue.Clone as TJSONValue);
        finally
          LRetPedido.Free;
        end;
      except
        on E: Exception do
        begin
          Inc(LErros);
          LResultadoItem.AddPair('success', TJSONFalse.Create);
          LResultadoItem.AddPair('error', E.Message);
        end;
      end;
    end;

    Result := TJSONObject.Create;
    if LErros = 0 then
      Result.AddPair('success', TJSONTrue.Create)
    else
      Result.AddPair('success', TJSONFalse.Create);
    Result.AddPair('totalRecebido', TJSONNumber.Create(APedidos.Count));
    Result.AddPair('totalInseridos', TJSONNumber.Create(LInseridos));
    Result.AddPair('totalComErro', TJSONNumber.Create(LErros));
    Result.AddPair('resultados', LResultados.Clone as TJSONValue);
  finally
    LResultados.Free;
  end;
end;

class function TWorbyRepRestDatabase.LoginTbusu(const ALogin,
  ASenha: string): TJSONObject;
var
  LQuery: TFDQuery;
begin
  LQuery := ExecuteQuery(
    'select u.*, coalesce(r.funcionario::varchar, '''') as funcionario ' +
    'from tbusu u ' +
    'left join representante r on r.id = u.cod_representante ' +
    'where u.logusu = :p0 and u.senusu = :p1 ' +
    '  and u.cod_representante is not null ' +
    '  and trim(coalesce(u.cod_representante::varchar, '''')) <> '''' ' +
    'limit 1',
    [ALogin, ASenha]
  );
  try
    Result := QueryRowToJson(LQuery, ['senusu']);
  finally
    LQuery.Free;
  end;
end;

class function TWorbyRepRestDatabase.GetConnection: TFDConnection;
begin
  if FConnection = nil then
  begin
    FConnection := TFDConnection.Create(nil);
    ConfigureConnection;
  end;

  if not FConnection.Connected then
    FConnection.Connected := True;

  Result := FConnection;
end;

class function TWorbyRepRestDatabase.ListTable(const ATable: TTableInfo;
  ALimit: Integer; AOffset: Integer; const ACodRepresentante: string;
  const ADataUltSincronizacao: string; const ANumDocsCsv: string): TJSONArray;
var
  LQuery: TFDQuery;
  LSql: string;
  LCodRepresentanteInt: Int64;
  LUltSync: TDateTime;
begin

//  ALimit := 5;

  if SameText(ATable.Name, 'cliente') then
  begin
    if (ALimit <= 0) or (ALimit > CMaxClienteSyncPageSize) then
      ALimit := CMaxClienteSyncPageSize;
  end;

  if SameText(ATable.Name, 'representante') and (Trim(ACodRepresentante) <> '') then
  begin
    if not TryStrToInt64(Trim(ACodRepresentante), LCodRepresentanteInt) then
      raise Exception.Create('Valor de filtro invalido para campo numerico');

    LSql := 'select * from representante where id = :p0';
    if ALimit > 0 then
    begin
      LSql := LSql + Format(' limit %d', [ALimit]);
      if AOffset > 0 then
        LSql := LSql + Format(' offset %d', [AOffset]);
    end;
    LQuery := ExecuteQuery(LSql, [LCodRepresentanteInt]);
  end
  else
  if SameText(ATable.Name, 'cliente') and (Trim(ACodRepresentante) <> '') then
  begin
    if not TryStrToInt64(Trim(ACodRepresentante), LCodRepresentanteInt) then
      raise Exception.Create('Valor de filtro invalido para campo numerico');

    LSql :=
      'select * from cliente ' +
      'where id_representante = :p0 ' +
      'order by cod_cliente ';

    if ALimit > 0 then
    begin
      LSql := LSql + Format(' limit %d', [ALimit]);
      if AOffset > 0 then
        LSql := LSql + Format(' offset %d', [AOffset]);
    end;

    LQuery := ExecuteQuery(LSql, [LCodRepresentanteInt]);
  end
  else
  if SameText(ATable.Name, 'produto') then
  begin
    if Trim(ACodRepresentante) <> '' then
    begin
      if not TryStrToInt64(Trim(ACodRepresentante), LCodRepresentanteInt) then
        raise Exception.Create('Valor de filtro invalido para campo numerico');

      LSql :=
        'select p.*, ' +
        '  case when coalesce(p.promocao, ''N'') = ''S'' then 0 else ' +
        '    coalesce( ' +
        '      nullif((select pr.desconto_maximo from produto_representante pr ' +
        '              where pr.cod_produto = p.cod_produto and pr.id_representante = :p0 limit 1), 0), ' +
        '      nullif((select gr.desconto_maximo from grupo_representante gr ' +
        '              where gr.cod_grupo = p.cod_grupo and gr.id_representante = :p0 limit 1), 0), ' +
        '      p.desconto_maximo ' +
        '    ) ' +
        '  end as desconto_maximo_app ' +
        'from produto p ' +
        'where COALESCE(p.status, ''N'') <> ''S'' ' +
        '  and COALESCE(p.indisponivel, ''N'') <> ''S'' ';
    end
    else
      LSql :=
        'select p.* ' +
        'from produto p ' +
        'where COALESCE(p.status, ''N'') <> ''S'' ' +
        '  and COALESCE(p.indisponivel, ''N'') <> ''S'' ';

    if (Trim(ADataUltSincronizacao) <> '') and (Trim(ACodRepresentante) = '') then
    begin
      LUltSync := ParseApiDateTime(ADataUltSincronizacao, 0);
      if LUltSync = 0 then
        raise Exception.Create('Data de ultima sincronizacao invalida');

      LSql := LSql + '  and p.dta_ult_atualizacao >= :p0 ';
    end;

    LSql := LSql +
      'order by cod_produto ';
    if ALimit > 0 then
    begin
      LSql := LSql + Format(' limit %d', [ALimit]);
      if AOffset > 0 then
        LSql := LSql + Format(' offset %d', [AOffset]);
    end;
    if Trim(ACodRepresentante) <> '' then
    begin
      LQuery := ExecuteQuery(LSql, [LCodRepresentanteInt]);
    end
    else if Trim(ADataUltSincronizacao) <> '' then
      LQuery := ExecuteQuery(LSql, [LUltSync])
    else
      LQuery := ExecuteQuery(LSql, []);
  end
  else
  if SameText(ATable.Name, 'subcategoria') then
  begin
    LSql :=
      'select * from subcategoria ';

    if Trim(ADataUltSincronizacao) <> '' then
    begin
      LUltSync := ParseApiDateTime(ADataUltSincronizacao, 0);
      if LUltSync = 0 then
        raise Exception.Create('Data de ultima sincronizacao invalida');

      LSql := LSql +
        'where dta_ult_atualizacao >= :p0 ';
    end;

    LSql := LSql + 'order by id';
    if ALimit > 0 then
    begin
      LSql := LSql + Format(' limit %d', [ALimit]);
      if AOffset > 0 then
        LSql := LSql + Format(' offset %d', [AOffset]);
    end;

    if Trim(ADataUltSincronizacao) <> '' then
      LQuery := ExecuteQuery(LSql, [LUltSync])
    else
      LQuery := ExecuteQuery(LSql, []);
  end
  else
  if SameText(ATable.Name, 'cidades') then
  begin
    LSql :=
      'select * from cidades order by cod_cidade ';

    if ALimit > 0 then
    begin
      LSql := LSql + Format(' limit %d', [ALimit]);
      if AOffset > 0 then
        LSql := LSql + Format(' offset %d', [AOffset]);
    end;

    LQuery := ExecuteQuery(LSql, []);
  end
  else
  if SameText(ATable.Name, 'vendas1') and (Trim(ACodRepresentante) <> '') then
  begin
    if not TryStrToInt64(Trim(ACodRepresentante), LCodRepresentanteInt) then
      raise Exception.Create('Valor de filtro invalido para campo numerico');


    LSql :=
      'SELECT * '+
      'FROM ( '+
      ' SELECT '+
      '   v1.*, '+
      '   ROW_NUMBER() OVER ( '+
      '     PARTITION BY v1.cod_cliente '+
      '     ORDER BY v1.dtadoc DESC '+
      '   ) AS rn '+
      ' FROM vendas1 v1 '+
      ' WHERE v1.cod_cliente IN ( '+
      '   SELECT c.cod_cliente '+
      '   FROM cliente c '+
      '   WHERE c.id_representante = :p0 '+
      ' ) '+
      ' AND (coalesce(v1.consignacao, 0) <> 1 and coalesce(v1.orcamento, 0) = 0) '+
      ' AND v1.faturado in (1) '+
      ' AND (v1.cod_fiscal not in (''6152'', ''6409'') OR v1.cod_fiscal IS NULL) '+
      ' AND v1.numdoc_grupo IS NULL '+
      ' AND v1.nfeentradasaida = ''0'' '+
      ' AND v1.numdoc NOT IN ( '+
      '   SELECT v1b.numdoc_ref_ent '+
      '   FROM vendas1 v1b '+
      '   WHERE v1b.faturado <> 2 '+
      '     AND v1b.nfeentradasaida = ''1'' '+
      '     AND v1b.numdoc_ref_ent IS NOT NULL '+
      ' ) '+
      ' AND (v1.nfe_dev is null or v1.status_nfe_dev = 135) '+
      ' AND v1.cod_fop not in (7, 9, 22, 23, 24, 26, 32, 46, 47, 51, 52, 53, 54, 57, 58) '+
      ') t '+
      'WHERE t.rn <= 20 ';

    if ALimit > 0 then
    begin
      LSql := LSql + ' order by t.numdoc desc';
      LSql := LSql + Format(' limit %d', [ALimit]);
      if AOffset > 0 then
        LSql := LSql + Format(' offset %d', [AOffset]);
    end;

    LQuery := ExecuteQuery(LSql, [LCodRepresentanteInt]);
  end
  else
  if SameText(ATable.Name, 'vendas2') and (Trim(ANumDocsCsv) <> '') then
  begin
    LSql :=
      'SELECT v2.numdoc, v2.cod_produto, v2.qtd, v2.preco, v2.desconto, v2.cod_cliente, v2.cod_representante ' +
      'FROM vendas2 v2 ' +
      'WHERE v2.numdoc IN (' + ANumDocsCsv + ') ' +
      'ORDER BY v2.numdoc, v2.cod_produto ';

    if ALimit > 0 then
    begin
      LSql := LSql + Format(' limit %d', [ALimit]);
      if AOffset > 0 then
        LSql := LSql + Format(' offset %d', [AOffset]);
    end;
    LQuery := ExecuteQuery(LSql, []);
  end
  else
  if SameText(ATable.Name, 'vendas2') and (Trim(ACodRepresentante) <> '') then
  begin
    if not TryStrToInt64(Trim(ACodRepresentante), LCodRepresentanteInt) then
      raise Exception.Create('Valor de filtro invalido para campo numerico');

    LSql :=
      'WITH ult AS ( ' +
      '  SELECT t.numdoc ' +
      '  FROM ( ' +
      '    SELECT v1.numdoc, ' +
      '           ROW_NUMBER() OVER (PARTITION BY v1.cod_cliente ORDER BY v1.dtadoc DESC) AS rn ' +
      '    FROM vendas1 v1 ' +
      '    WHERE v1.cod_cliente IN ( ' +
      '      SELECT c.cod_cliente FROM cliente c WHERE c.id_representante = :p0 ' +
      '    ) ' +
      '  ) t ' +
      '  WHERE t.rn <= 5 ' +
      ') ' +
      'SELECT v2.numdoc, v2.cod_produto, v2.qtd, v2.preco, v2.desconto, v2.cod_cliente, v2.cod_representante ' +
      'FROM vendas2 v2 ' +
      'INNER JOIN ult u ON u.numdoc = v2.numdoc ' +
      'ORDER BY v2.numdoc, v2.cod_produto ';

    if ALimit > 0 then
    begin
      LSql := LSql + Format(' limit %d', [ALimit]);
      if AOffset > 0 then
        LSql := LSql + Format(' offset %d', [AOffset]);
    end;

    LQuery := ExecuteQuery(LSql, [LCodRepresentanteInt]);
  end
  else
  if SameText(ATable.Name, 'cr1') and (Trim(ACodRepresentante) <> '') then
  begin
    if not TryStrToInt64(Trim(ACodRepresentante), LCodRepresentanteInt) then
      raise Exception.Create('Valor de filtro invalido para campo numerico');

    LSql :=
      'select cr.titulo, cr.sequencia, cr.cod_cliente, cr.dtaven, cr.valor, ' +
      '       cr.valor_recebido, cr.dtarec, cr.cod_fop, cr.nr_documento ' +
      'from cr1 cr ' +
      'left join cliente c on c.cod_cliente = cr.cod_cliente ' +
      'where (cr.id_representante = :p0 or c.id_representante = :p0) ' +
      '  and cr.dtarec is null ' +
      'order by cr.dtaven, cr.titulo, cr.sequencia ';

    if ALimit > 0 then
    begin
      LSql := LSql + Format(' limit %d', [ALimit]);
      if AOffset > 0 then
        LSql := LSql + Format(' offset %d', [AOffset]);
    end;
    LQuery := ExecuteQuery(LSql, [LCodRepresentanteInt]);
  end
  else
  if SameText(ATable.Name, 'fop') then
  begin
    LSql :=
      'select * from fop ' +
      'where coalesce(inativo_palm, ''N'') <> ''S'' ' +
      '  and coalesce(ativo, ''S'') = ''S''';
    if ALimit > 0 then
    begin
      LSql := LSql + Format(' limit %d', [ALimit]);
      if AOffset > 0 then
        LSql := LSql + Format(' offset %d', [AOffset]);
    end;
    LQuery := ExecuteQuery(LSql, []);
  end
  else
  if SameText(ATable.Name, 'prazo') then
  begin
    LSql :=
      'select * from prazo ' +
      'where coalesce(inativo_palm, ''N'') <> ''S'' ' +
      '  and coalesce(ativo, ''S'') = ''S''';
    if ALimit > 0 then
    begin
      LSql := LSql + Format(' limit %d', [ALimit]);
      if AOffset > 0 then
        LSql := LSql + Format(' offset %d', [AOffset]);
    end;
    LQuery := ExecuteQuery(LSql, []);
  end
  else
  if (Trim(ACodRepresentante) <> '') and (ATable.RepresentativeField <> '') then
  begin
    LSql := Format('select * from %s where %s = :p0',
      [ATable.Name, ATable.RepresentativeField]);

    if ALimit > 0 then
    begin
      LSql := LSql + Format(' limit %d', [ALimit]);
      if AOffset > 0 then
        LSql := LSql + Format(' offset %d', [AOffset]);
    end;

    case ATable.RepresentativeFieldType of
      tktInteger:
        begin
          if not TryStrToInt64(Trim(ACodRepresentante), LCodRepresentanteInt) then
            raise Exception.Create('Valor de filtro invalido para campo numerico');

          LQuery := ExecuteQuery(LSql, [LCodRepresentanteInt]);
        end;
    else
      LQuery := ExecuteQuery(LSql, [ACodRepresentante]);
    end;
  end
  else
  begin
    LSql := Format('select * from %s', [ATable.Name]);
    if ALimit > 0 then
    begin
      LSql := LSql + Format(' limit %d', [ALimit]);
      if AOffset > 0 then
        LSql := LSql + Format(' offset %d', [AOffset]);
    end;

    LQuery := ExecuteQuery(
      LSql,
      []
    );
  end;
  try
    Result := QueryToJsonArray(LQuery);
    if CGeocodeClientesAtivo and SameText(ATable.Name, 'cliente') then
    begin
      BeginGeocodeProgress(ACodRepresentante, Result.Count);
      try
        PreencherGeolocalizacaoClientes(Result);
      finally
        EndGeocodeProgress;
      end;
    end;
  finally
    LQuery.Free;
  end;
end;

class function TWorbyRepRestDatabase.CountTable(const ATable: TTableInfo;
  const ACodRepresentante: string; const ADataUltSincronizacao: string;
  const ANumDocsCsv: string): Integer;
var
  LQuery: TFDQuery;
  LSql: string;
  LCodRepresentanteInt: Int64;
  LUltSync: TDateTime;
begin
  if SameText(ATable.Name, 'cliente') and (Trim(ACodRepresentante) <> '') then
  begin
    if not TryStrToInt64(Trim(ACodRepresentante), LCodRepresentanteInt) then
      raise Exception.Create('Valor de filtro invalido para campo numerico');

    LQuery := ExecuteQuery(
      'select count(*) from cliente where id_representante = :p0',
      [LCodRepresentanteInt]
    );
  end
  else if SameText(ATable.Name, 'produto') then
  begin
    LSql :=
      'select count(*) ' +
      'from produto p ' +
      'where COALESCE(p.status, ''N'') <> ''S'' ' +
      '  and COALESCE(p.indisponivel, ''N'') <> ''S'' ';

    if Trim(ADataUltSincronizacao) <> '' then
    begin
      LUltSync := ParseApiDateTime(ADataUltSincronizacao, 0);
      if LUltSync = 0 then
        raise Exception.Create('Data de ultima sincronizacao invalida');

      LSql := LSql + ' and p.dta_ult_atualizacao >= :p0';
      LQuery := ExecuteQuery(LSql, [LUltSync]);
    end
    else
      LQuery := ExecuteQuery(LSql, []);
  end
  else if SameText(ATable.Name, 'subcategoria') and (Trim(ADataUltSincronizacao) <> '') then
  begin
    LUltSync := ParseApiDateTime(ADataUltSincronizacao, 0);
    if LUltSync = 0 then
      raise Exception.Create('Data de ultima sincronizacao invalida');

    LQuery := ExecuteQuery(
      'select count(*) from subcategoria where dta_ult_atualizacao >= :p0',
      [LUltSync]
    );
  end
  else if (Trim(ACodRepresentante) <> '') and (ATable.RepresentativeField <> '') then
  begin
    LSql := Format('select count(*) from %s where %s = :p0',
      [ATable.Name, ATable.RepresentativeField]);

    case ATable.RepresentativeFieldType of
      tktInteger:
        begin
          if not TryStrToInt64(Trim(ACodRepresentante), LCodRepresentanteInt) then
            raise Exception.Create('Valor de filtro invalido para campo numerico');
          LQuery := ExecuteQuery(LSql, [LCodRepresentanteInt]);
        end;
    else
      LQuery := ExecuteQuery(LSql, [ACodRepresentante]);
    end;
  end
  else
    LQuery := ExecuteQuery(Format('select count(*) from %s', [ATable.Name]), []);

  try
    if LQuery.Eof then
      Result := 0
    else
      Result := LQuery.Fields[0].AsInteger;
  finally
    LQuery.Free;
  end;
end;

class function TWorbyRepRestDatabase.GetClienteByDocumento(
  const ADocumento: string): TJSONObject;
var
  LQuery: TFDQuery;
  LDoc: string;
begin
  LDoc := Trim(ADocumento);
  LDoc := StringReplace(LDoc, '.', '', [rfReplaceAll]);
  LDoc := StringReplace(LDoc, '/', '', [rfReplaceAll]);
  LDoc := StringReplace(LDoc, '-', '', [rfReplaceAll]);
  LDoc := StringReplace(LDoc, ' ', '', [rfReplaceAll]);

  if LDoc = '' then
    Exit(nil);

  LQuery := ExecuteQuery(
    'select a.cod_cliente, a.nom_cliente, a.nom_fantasia, a.cnpj, a.cpf, a.ie, ' +
    '       a.cep, a.endereco, a.nr_endereco, a.complemento, a.bairro, ' +
    '       a.telefone, a.email, a.email_end_nfe, ' +
    '       a.cod_cidade, c.cod_ibge, c.nom_cidade, c.uf, a.tip_pessoa, a.consumidor_final ' +
    'from cliente a ' +
    'left join cidades c on c.cod_cidade = a.cod_cidade ' +
    'where regexp_replace(coalesce(a.cnpj, ''''), ''[^0-9]'', '''', ''g'') = :p0 ' +
    '   or regexp_replace(coalesce(a.cpf, ''''), ''[^0-9]'', '''', ''g'') = :p0 ' +
    'limit 1',
    [LDoc]
  );
  try
    Result := QueryRowToJson(LQuery, []);
  finally
    LQuery.Free;
  end;
end;

class function TWorbyRepRestDatabase.GetMetaRepresentante(ACodRepresentante: Integer; const AMes: string): TJSONObject;
var
  LQuery: TFDQuery;
  LInfoQuery: TFDQuery;
  LRepField: string;
  LMesDataType: string;
  LMesNum: Integer;
  LAnoNum: Integer;
  LInicio: TDateTime;
  LFim: TDateTime;
  LSql: string;

  function ColumnExists(const AColumnName: string): Boolean;
  begin
    LInfoQuery.Close;
    LInfoQuery.SQL.Text :=
      'select 1 from information_schema.columns ' +
      'where table_schema = ''public'' and table_name = ''metas_representante'' and column_name = :p0';
    LInfoQuery.ParamByName('p0').AsString := AColumnName;
    LInfoQuery.Open;
    Result := not LInfoQuery.Eof;
  end;

begin
  if (Length(Trim(AMes)) <> 7) or (AMes[3] <> '/') then
    raise Exception.Create('Mes invalido. Use MM/AAAA.');

  LMesNum := StrToIntDef(Copy(AMes, 1, 2), 0);
  LAnoNum := StrToIntDef(Copy(AMes, 4, 4), 0);
  if (LMesNum < 1) or (LMesNum > 12) or (LAnoNum <= 0) then
    raise Exception.Create('Mes invalido. Use MM/AAAA.');

  LInicio := EncodeDate(LAnoNum, LMesNum, 1);
  LFim := IncMonth(LInicio, 1);
  LRepField := 'cod_representante';
  LMesDataType := '';

  LInfoQuery := TFDQuery.Create(nil);
  try
    LInfoQuery.Connection := GetConnection;
    if not ColumnExists(LRepField) then
      LRepField := 'id_representante';

    LInfoQuery.Close;
    LInfoQuery.SQL.Text :=
      'select data_type from information_schema.columns ' +
      'where table_schema = ''public'' and table_name = ''metas_representante'' and column_name = ''mes''';
    LInfoQuery.Open;
    if not LInfoQuery.Eof then
      LMesDataType := LowerCase(LInfoQuery.Fields[0].AsString);
  finally
    LInfoQuery.Free;
  end;

  LSql :=
    'SELECT ' +
    '  id, ' +
    '  mes, ' +
    '  ' + LRepField + ' as id_representante, ' +
    '  vl_meta, ' +
    '  vl_realizado, ' +
    '  perc_realizado, ' +
    '  qtd_clientes_atendidos, ' +
    '  qtd_clientes_base, ' +
    '  perc_positivacao, ' +
    '  ticket_medio, ' +
    '  perc_desconto ' +
    'FROM metas_representante ' +
    'where ' + LRepField + ' = :p0 ';

  if (Pos('date', LMesDataType) > 0) or (Pos('timestamp', LMesDataType) > 0) then
    LQuery := ExecuteQuery(LSql + ' and mes >= :p1 and mes < :p2', [ACodRepresentante, LInicio, LFim])
  else
    LQuery := ExecuteQuery(
      LSql + ' and (trim(mes::varchar) = :p1 or trim(mes::varchar) = :p2)',
      [ACodRepresentante, AMes, FormatDateTime('yyyymm', LInicio)]
    );
  try
    if LQuery.Eof then
    begin
      Result := TJSONObject.Create;
      Result.AddPair('found', 'false');
    end
    else
    begin
      Result := QueryRowToJson(LQuery, []);
      Result.AddPair('found', 'true');
    end;
  finally
    LQuery.Free;
  end;
end;

class function TWorbyRepRestDatabase.GetMesesDashboard(ACodRepresentante: Integer): TJSONArray;
var
  LQuery: TFDQuery;
  LSql: string;
  LItem: TJSONObject;
  LMes: string;

begin
  LSql :=
    'select mes from (' +
    'select distinct ' +
    '       case ' +
    '         when trim(mes::varchar) ~ ''^[0-9]{1,2}/[0-9]{4}$'' then lpad(split_part(trim(mes::varchar), ''/'', 1), 2, ''0'') || ''/'' || split_part(trim(mes::varchar), ''/'', 2) ' +
    '         when trim(mes::varchar) ~ ''^[0-9]{6}$'' then substr(trim(mes::varchar), 5, 2) || ''/'' || substr(trim(mes::varchar), 1, 4) ' +
    '         when trim(mes::varchar) ~ ''^[0-9]{4}-[0-9]{2}'' then substr(trim(mes::varchar), 6, 2) || ''/'' || substr(trim(mes::varchar), 1, 4) ' +
    '         else trim(mes::varchar) ' +
    '       end as mes, ' +
    '       case ' +
    '         when trim(mes::varchar) ~ ''^[0-9]{1,2}/[0-9]{4}$'' then split_part(trim(mes::varchar), ''/'', 2) ' +
    '         when trim(mes::varchar) ~ ''^[0-9]{6}$'' then substr(trim(mes::varchar), 1, 4) ' +
    '         when trim(mes::varchar) ~ ''^[0-9]{4}-[0-9]{2}'' then substr(trim(mes::varchar), 1, 4) ' +
    '         else null ' +
    '       end as ordem_ano, ' +
    '       case ' +
    '         when trim(mes::varchar) ~ ''^[0-9]{1,2}/[0-9]{4}$'' then lpad(split_part(trim(mes::varchar), ''/'', 1), 2, ''0'') ' +
    '         when trim(mes::varchar) ~ ''^[0-9]{6}$'' then substr(trim(mes::varchar), 5, 2) ' +
    '         when trim(mes::varchar) ~ ''^[0-9]{4}-[0-9]{2}'' then substr(trim(mes::varchar), 6, 2) ' +
    '         else null ' +
    '       end as ordem_mes ' +
    'from metas_representante ' +
    'where coalesce(trim(mes::varchar), '''') <> '''' ' +
    ') x ' +
    'order by ordem_ano desc nulls last, ordem_mes desc nulls last, mes desc';

  LQuery := ExecuteQuery(LSql, []);
  try
    Result := TJSONArray.Create;
    LQuery.First;
    while not LQuery.Eof do
    begin
      LMes := Trim(LQuery.FieldByName('mes').AsString);
      if LMes <> '' then
      begin
        LItem := TJSONObject.Create;
        LItem.AddPair('mes', LMes);
        Result.AddElement(LItem);
      end;
      LQuery.Next;
    end;
  finally
    LQuery.Free;
  end;
end;

class function TWorbyRepRestDatabase.GetPedidosFaturadosDashboard(ACodRepresentante: Integer; const AMes, AStatus: string;
  ADiaInicial, ADiaFinal: Integer; const ABusca: string): TJSONObject;
var
  LQuery: TFDQuery;
  LPedidos: TJSONArray;
  LPedido: TJSONObject;
  LField: TField;
  LTotalFaturado: Double;
  LTotalBruto: Double;
  LTotalComissao: Double;
  LTotalPercComissao: Double;
  LTotalPercDesconto: Double;
  LQtd: Integer;
  LInicio: TDateTime;
  LFim: TDateTime;
  LMesNum: Integer;
  LAnoNum: Integer;
  LDiasNoMes: Integer;
  LStatus: string;
  LDataField: string;
  LBusca: string;
  LSql: string;

  function FieldFloat(const AName: string): Double;
  begin
    Result := 0;
    if not LQuery.FieldByName(AName).IsNull then
      Result := LQuery.FieldByName(AName).AsFloat;
  end;

  function BuildPedidosSql(const ADataField, AFaturado: string): string;
  begin
    Result :=
      'select ' +
      '  v1.numdoc, ' +
      '  coalesce(v1.numdoc_destino, v1.numdoc) as numdoc_destino, ' +
      '  v1.dtadoc, ' +
      '  v1.dta_emissao, ' +
      '  ' + ADataField + ' as data_filtro, ' +
      '  c.cod_cliente, ' +
      '  c.nom_cliente, ' +
      '  r.id as codrep, ' +
      '  r.nom_representante, ' +
      '  coalesce(v1.perc_comissao, 0) as perc_comissao, ' +
      '  coalesce(v1.vlr_comissao, 0) as vlr_comissao, ' +
      '  coalesce(v1.tot_bruto, 0) as tot_bruto, ' +
      '  coalesce(v1.tot_liquido, 0) as tot_liquido, ' +
      '  coalesce(v1.desconto, 0) as desconto, ' +
      '  v1.faturado ' +
      'from vendas1 v1 ' +
      'left join cliente c on c.cod_cliente = v1.cod_cliente ' +
      'left join cidades cd on cd.cod_cidade = c.cod_cidade ' +
      'inner join representante r on r.id = v1.cod_representante ' +
      'where ' +
      '  (v1.cod_fiscal not in (''6152'', ''6409'') or v1.cod_fiscal is null) ' +
      '  and v1.nfeentradasaida = ''0'' ' +
      '  and (v1.numdoc not in (select numdoc_ref_ent from vendas1 where faturado <> 2 and nfeentradasaida = ''1'' and numdoc_ref_ent is not null)) ' +
      '  and (v1.nfe_dev is null or v1.status_nfe_dev = 135) ' +
      '  and coalesce(v1.consignacao, 0) <> 1 ' +
      '  and coalesce(v1.cod_fop, 0) not in (7, 9, 22, 23, 24, 26, 32, 46, 47, 51, 52, 53, 54, 57, 58) ' +
      '  and v1.cod_representante = :p0 ' +
      '  and ' + ADataField + ' between :p1 and :p2 ' +
      '  and v1.orcamento = ''0'' ';

    if AFaturado <> '' then
      Result := Result + ' and v1.faturado = ''' + AFaturado + ''' ';

    if LBusca <> '' then
      Result := Result +
        ' and (cast(v1.numdoc as varchar) ilike :p3 ' +
        '   or cast(coalesce(v1.numdoc_destino, v1.numdoc) as varchar) ilike :p3 ' +
        '   or coalesce(c.nom_cliente, '''') ilike :p3) ';
  end;

begin
  if (Length(Trim(AMes)) <> 7) or (AMes[3] <> '/') then
    raise Exception.Create('Mes invalido. Use MM/AAAA.');

  LMesNum := StrToIntDef(Copy(AMes, 1, 2), 0);
  LAnoNum := StrToIntDef(Copy(AMes, 4, 4), 0);
  if (LMesNum < 1) or (LMesNum > 12) or (LAnoNum <= 0) then
    raise Exception.Create('Mes invalido. Use MM/AAAA.');

  LDiasNoMes := DayOf(EndOfTheMonth(EncodeDate(LAnoNum, LMesNum, 1)));
  if ADiaInicial <= 0 then
    ADiaInicial := 1;
  if ADiaFinal <= 0 then
    ADiaFinal := LDiasNoMes;
  ADiaInicial := EnsureRange(ADiaInicial, 1, LDiasNoMes);
  ADiaFinal := EnsureRange(ADiaFinal, ADiaInicial, LDiasNoMes);

  LInicio := EncodeDate(LAnoNum, LMesNum, ADiaInicial);
  LFim := RecodeTime(EncodeDate(LAnoNum, LMesNum, ADiaFinal), 23, 59, 59, 999);
  LStatus := UpperCase(Trim(AStatus));
  if LStatus = 'ABERTO' then
  begin
    LDataField := 'v1.dtadoc';
  end
  else if LStatus = 'FATURADO' then
  begin
    LDataField := 'v1.dta_emissao';
  end
  else
  begin
    LStatus := 'TODOS';
    LDataField := '';
  end;
  LBusca := Trim(ABusca);

  LTotalFaturado := 0;
  LTotalBruto := 0;
  LTotalComissao := 0;
  LTotalPercComissao := 0;
  LTotalPercDesconto := 0;
  LQtd := 0;

  if LStatus = 'TODOS' then
    LSql := BuildPedidosSql('v1.dta_emissao', '1') +
      ' union all ' +
      BuildPedidosSql('v1.dtadoc', '0') +
      ' order by data_filtro desc, numdoc desc'
  else if LStatus = 'FATURADO' then
    LSql := BuildPedidosSql(LDataField, '1') + ' order by data_filtro desc, numdoc desc'
  else
    LSql := BuildPedidosSql(LDataField, '0') + ' order by data_filtro desc, numdoc desc';

  if LBusca <> '' then
    LQuery := ExecuteQuery(LSql, [ACodRepresentante, LInicio, LFim, '%' + LBusca + '%'])
  else
    LQuery := ExecuteQuery(LSql, [ACodRepresentante, LInicio, LFim]);


  LQuery.sql.SaveToFile('teste.sql');
  try
    LPedidos := TJSONArray.Create;
    try
      while not LQuery.Eof do
      begin
        Inc(LQtd);
        LTotalFaturado := LTotalFaturado + FieldFloat('tot_liquido');
        LTotalBruto := LTotalBruto + FieldFloat('tot_bruto');
        LTotalComissao := LTotalComissao + FieldFloat('vlr_comissao');
        LTotalPercComissao := LTotalPercComissao + FieldFloat('perc_comissao');
        LTotalPercDesconto := LTotalPercDesconto + FieldFloat('desconto');

        if LPedidos.Count < 100 then
        begin
          LPedido := TJSONObject.Create;
          for LField in LQuery.Fields do
            LPedido.AddPair(LField.FieldName, FieldValueToJson(LField));
          LPedidos.AddElement(LPedido);
        end;

        LQuery.Next;
      end;

      Result := TJSONObject.Create;
      Result.AddPair('found', BoolToStr(LQtd > 0, True));
      Result.AddPair('mes', AMes);
      Result.AddPair('status', LStatus);
      Result.AddPair('qtd_pedidos', TJSONNumber.Create(LQtd));
      Result.AddPair('total_faturado', TJSONNumber.Create(LTotalFaturado));
      if LTotalBruto > 0 then
        Result.AddPair('perc_desconto_medio', TJSONNumber.Create(100 - ((LTotalFaturado / LTotalBruto) * 100)))
      else if LQtd > 0 then
        Result.AddPair('perc_desconto_medio', TJSONNumber.Create(LTotalPercDesconto / LQtd))
      else
        Result.AddPair('perc_desconto_medio', TJSONNumber.Create(0));
      Result.AddPair('total_comissao', TJSONNumber.Create(LTotalComissao));
      if LQtd > 0 then
        Result.AddPair('perc_comissao_media', TJSONNumber.Create(LTotalPercComissao / LQtd))
      else
        Result.AddPair('perc_comissao_media', TJSONNumber.Create(0));
      Result.AddPair('pedidos', LPedidos);
    except
      LPedidos.Free;
      raise;
    end;
  finally
    LQuery.Free;
  end;
end;

class function TWorbyRepRestDatabase.UpsertCliente(ACliente: TJSONObject): TJSONObject;
var
  LConnection: TFDConnection;
  LQuery: TFDQuery;
  LDocumento: string;
  LExistente: TJSONObject;
  LCodCliente: Integer;
  LCodCidade: Integer;
  LCodIbge: Integer;
  LTipPessoa: string;
  LNome: string;
  LFantasia: string;
  LCidade: string;
  LUf: string;
  LCodRepresentante: Integer;
  LClienteExiste: Boolean;

  function JStr(const AName: string): string;
  var
    V: TJSONValue;
  begin
    Result := '';
    if not Assigned(ACliente) then
      Exit;
    V := ACliente.GetValue(AName);
    if Assigned(V) and not (V is TJSONNull) then
      Result := Trim(V.Value);
  end;

  function JInt(const AName: string; ADefault: Integer = 0): Integer;
  begin
    Result := StrToIntDef(JStr(AName), ADefault);
  end;

    function OnlyDigits(const AValue: string): string;
  var
    I: Integer;
  begin
    Result := '';
    for I := 1 to Length(AValue) do
      if CharInSet(AValue[I], ['0'..'9']) then
        Result := Result + AValue[I];
  end;

  function FormatarTelefone(const AValue: string): string;
  var
    LValue: string;
    LDigits: string;
    LPos: Integer;
  begin
    LValue := Trim(AValue);
    LPos := Pos('/', LValue);
    if LPos > 0 then
      LValue := Copy(LValue, 1, LPos - 1);

    LDigits := OnlyDigits(LValue);
    if Length(LDigits) > 11 then
      LDigits := Copy(LDigits, 1, 11);

    if Length(LDigits) = 11 then
      Result := '(' + Copy(LDigits, 1, 2) + ')' + Copy(LDigits, 3, 5) + '-' + Copy(LDigits, 8, 4)
    else if Length(LDigits) = 10 then
      Result := '(' + Copy(LDigits, 1, 2) + ')' + Copy(LDigits, 3, 4) + '-' + Copy(LDigits, 7, 4)
    else
      Result := Copy(LDigits, 1, 14);
  end;

  function FormatarDocumento(const AValue, ATipPessoa: string): string;
  var
    LDigits: string;
  begin
    LDigits := OnlyDigits(AValue);
    Result := LDigits;
    if SameText(ATipPessoa, 'F') then
    begin
      if Length(LDigits) = 11 then
        Result := Copy(LDigits, 1, 3) + '.' +
          Copy(LDigits, 4, 3) + '.' +
          Copy(LDigits, 7, 3) + '-' +
          Copy(LDigits, 10, 2);
    end
    else
    begin
      if Length(LDigits) = 14 then
        Result := Copy(LDigits, 1, 2) + '.' +
          Copy(LDigits, 3, 3) + '.' +
          Copy(LDigits, 6, 3) + '/' +
          Copy(LDigits, 9, 4) + '-' +
          Copy(LDigits, 13, 2);
    end;
  end;
begin
  if not Assigned(ACliente) then
    raise Exception.Create('Objeto cliente e obrigatorio');

  LTipPessoa := UpperCase(Copy(JStr('tip_pessoa'), 1, 1));
  if LTipPessoa = '' then
    LTipPessoa := 'J';

  if LTipPessoa = 'F' then
    LDocumento := JStr('cpf')
  else
    LDocumento := JStr('cnpj');

  LDocumento := FormatarDocumento(LDocumento, LTipPessoa);

  if LDocumento = '' then
    raise Exception.Create('Documento do cliente e obrigatorio');

  LNome := JStr('nom_cliente');
  if LNome = '' then
    LNome := LDocumento;
  LFantasia := JStr('nom_fantasia');
  LCidade := JStr('nom_cidade');
  LUf := JStr('uf');
  LCodRepresentante := JInt('id_representante');
  LCodCidade := JInt('cod_cidade');
  LCodIbge := JInt('cod_ibge');

  LClienteExiste := False;
  LExistente := GetClienteByDocumento(LDocumento);
  try
    if Assigned(LExistente) then
    begin
      LCodCliente := LExistente.GetValue<Integer>('cod_cliente', 0);
      LClienteExiste := LCodCliente > 0;
    end
    else
      LCodCliente := JInt('cod_cliente');
  finally
    LExistente.Free;
  end;

  LConnection := GetConnection;
  if not LConnection.InTransaction then
    LConnection.StartTransaction;
  LQuery := TFDQuery.Create(nil);
  try
    LQuery.Connection := LConnection;

    if (LCodCidade <= 0) and (LCodIbge > 0) then
    begin
      LQuery.SQL.Text := 'select cod_cidade from cidades where cod_ibge = :ibge limit 1';
      LQuery.ParamByName('ibge').AsInteger := LCodIbge;
      LQuery.Open;
      if not LQuery.IsEmpty then
        LCodCidade := LQuery.Fields[0].AsInteger;
      LQuery.Close;
    end;

    if (LCodCidade <= 0) and (LCidade <> '') and (LUf <> '') then
    begin
      LQuery.SQL.Text :=
        'select cod_cidade from cidades ' +
        'where upper(nom_cidade) = upper(:cidade) and upper(uf) = upper(:uf) limit 1';
      LQuery.ParamByName('cidade').AsString := LCidade;
      LQuery.ParamByName('uf').AsString := LUf;
      LQuery.Open;
      if not LQuery.IsEmpty then
        LCodCidade := LQuery.Fields[0].AsInteger;
      LQuery.Close;
    end;

    if LCodCliente <= 0 then
    begin
      LQuery.SQL.Text := 'select coalesce(max(cod_cliente), 0) + 1 from cliente';
      LQuery.Open;
      LCodCliente := LQuery.Fields[0].AsInteger;
      LQuery.Close;
    end;

    if LClienteExiste then
      LQuery.SQL.Text :=
        'update cliente set ' +
        'nom_cliente = :nom_cliente, nom_fantasia = :nom_fantasia, tip_pessoa = :tip_pessoa, ' +
        'cnpj = :cnpj, cpf = :cpf, ie = :ie, cep = :cep, endereco = :endereco, nr_endereco = :nr_endereco, ' +
        'complemento = :complemento, bairro = :bairro, cod_cidade = :cod_cidade, ' +
        'telefone = :telefone, email = :email, email_end_nfe = :email_end_nfe, ' +
        'id_representante = :id_representante, sincronizar_palm = ''S'' ' +
        'where cod_cliente = :cod_cliente'
    else
      LQuery.SQL.Text :=
        'insert into cliente (' +
        'cod_cliente, dta_cad, nom_cliente, nom_fantasia, tip_pessoa, cnpj, cpf, ie, cep, endereco, nr_endereco, complemento, bairro, cod_cidade, telefone, email, email_end_nfe, id_representante, cod_empresa, status, cliente_bloqueado, pre_cadastro, sincronizar_palm, consumidor_final' +
        ') values (' +
        ':cod_cliente, current_date, :nom_cliente, :nom_fantasia, :tip_pessoa, :cnpj, :cpf, :ie, :cep, :endereco, :nr_endereco, :complemento, :bairro, :cod_cidade, :telefone, :email, :email_end_nfe, :id_representante, 0, ''N'', ''N'', ''S'', ''S'', ''S''' +
        ')';

    LQuery.ParamByName('cod_cliente').AsInteger := LCodCliente;
    LQuery.ParamByName('nom_cliente').AsString := LNome;
    LQuery.ParamByName('nom_fantasia').AsString := LFantasia;
    LQuery.ParamByName('tip_pessoa').AsString := LTipPessoa;
    if LTipPessoa = 'F' then
    begin
      LQuery.ParamByName('cnpj').DataType := ftString;
      LQuery.ParamByName('cnpj').Clear;
      LQuery.ParamByName('cpf').AsString := LDocumento;
    end
    else
    begin
      LQuery.ParamByName('cnpj').AsString := LDocumento;
      LQuery.ParamByName('cpf').DataType := ftString;
      LQuery.ParamByName('cpf').Clear;
    end;
    LQuery.ParamByName('ie').AsString := JStr('ie');
    LQuery.ParamByName('cep').AsString := JStr('cep');
    LQuery.ParamByName('endereco').AsString := JStr('endereco');
    LQuery.ParamByName('nr_endereco').AsString := JStr('nr_endereco');
    LQuery.ParamByName('complemento').AsString := JStr('complemento');
    LQuery.ParamByName('bairro').AsString := JStr('bairro');
    LQuery.ParamByName('telefone').AsString := FormatarTelefone(JStr('telefone'));
    LQuery.ParamByName('email').AsString := JStr('email');
    LQuery.ParamByName('email_end_nfe').AsString := JStr('email_end_nfe');
    if LCodCidade > 0 then
      LQuery.ParamByName('cod_cidade').AsInteger := LCodCidade
    else
    begin
      LQuery.ParamByName('cod_cidade').DataType := ftInteger;
      LQuery.ParamByName('cod_cidade').Clear;
    end;
    if LCodRepresentante > 0 then
      LQuery.ParamByName('id_representante').AsInteger := LCodRepresentante
    else
    begin
      LQuery.ParamByName('id_representante').DataType := ftInteger;
      LQuery.ParamByName('id_representante').Clear;
    end;
    LQuery.ExecSQL;

    LConnection.Commit;

    Result := TJSONObject.Create;
    Result.AddPair('success', TJSONTrue.Create);
    Result.AddPair('cod_cliente', TJSONNumber.Create(LCodCliente));
  except
    if LConnection.InTransaction then
      LConnection.Rollback;
    raise;
  end;
  LQuery.Free;
end;

class function TWorbyRepRestDatabase.InsertRepresentanteLocalizacao(ALocalizacao: TJSONObject): TJSONObject;
var
  LQuery: TFDQuery;
  LId: Int64;
  LCodRepresentante: Integer;
  LDataHora: string;
  LVelocidade: Double;
  LLatitude: Double;
  LLongitude: Double;
  LDataHoraValue: TDateTime;
begin
  if not Assigned(ALocalizacao) then
    raise Exception.Create('Objeto de localizacao e obrigatorio');

  LCodRepresentante := ALocalizacao.GetValue<Integer>('cod_representante', 0);
  LDataHora := Trim(ALocalizacao.GetValue<string>('datahora', ''));
  LVelocidade := ALocalizacao.GetValue<Double>('velocidade', 0);
  LLatitude := ALocalizacao.GetValue<Double>('latitude', 0);
  LLongitude := ALocalizacao.GetValue<Double>('longitude', 0);

  if LCodRepresentante <= 0 then
    raise Exception.Create('cod_representante invalido');
  if LDataHora = '' then
    LDataHora := FormatDateTime('yyyy-mm-dd hh:nn:ss', Now);
  LDataHoraValue := ParseApiDateTime(LDataHora, Now);

  LQuery := TFDQuery.Create(nil);
  try
    LQuery.Connection := GetConnection;
    LQuery.SQL.Text := 'select coalesce(max(id), 0) + 1 from representante_localizacao';
    LQuery.Open;
    LId := LQuery.Fields[0].AsLargeInt;
    LQuery.Close;

    LQuery.SQL.Text :=
      'insert into representante_localizacao ' +
      '(id, cod_representante, datahora, velocidade, latitude, longitude) ' +
      'values (:id, :cod_representante, :datahora, :velocidade, :latitude, :longitude)';
    LQuery.ParamByName('id').AsLargeInt := LId;
    LQuery.ParamByName('cod_representante').AsInteger := LCodRepresentante;
    LQuery.ParamByName('datahora').AsDateTime := LDataHoraValue;
    LQuery.ParamByName('velocidade').AsFloat := LVelocidade;
    LQuery.ParamByName('latitude').AsFloat := LLatitude;
    LQuery.ParamByName('longitude').AsFloat := LLongitude;
    LQuery.ExecSQL;
  finally
    LQuery.Free;
  end;

  Result := TJSONObject.Create;
  Result.AddPair('ok', TJSONTrue.Create);
  Result.AddPair('id', TJSONNumber.Create(LId));
end;

class function TWorbyRepRestDatabase.UpsertRepresentanteKmDiario(AResumo: TJSONObject): TJSONObject;
var
  LQuery: TFDQuery;
  LCodRepresentante: Integer;
  LData: string;
  LKmRodado: Double;
  LQtdPontos: Integer;
  LQtdSegmentos: Integer;
  LInicio: string;
  LFim: string;
begin
  if not Assigned(AResumo) then
    raise Exception.Create('Objeto de quilometragem e obrigatorio');

  LCodRepresentante := AResumo.GetValue<Integer>('cod_representante', 0);
  LData := Trim(AResumo.GetValue<string>('data', ''));
  LKmRodado := AResumo.GetValue<Double>('km_rodado', 0);
  LQtdPontos := AResumo.GetValue<Integer>('qtd_pontos', 0);
  LQtdSegmentos := AResumo.GetValue<Integer>('qtd_segmentos', 0);
  LInicio := Trim(AResumo.GetValue<string>('inicio', ''));
  LFim := Trim(AResumo.GetValue<string>('fim', ''));

  if LCodRepresentante <= 0 then
    raise Exception.Create('cod_representante invalido');
  if LData = '' then
    LData := FormatDateTime('yyyy-mm-dd', Date);

  LQuery := TFDQuery.Create(nil);
  try
    LQuery.Connection := GetConnection;
    LQuery.SQL.Text :=
      'create table if not exists public.representante_km_diario (' +
      'cod_representante integer not null, data date not null, ' +
      'km_rodado numeric(12,3) not null default 0, ' +
      'qtd_pontos integer not null default 0, qtd_segmentos integer not null default 0, ' +
      'inicio timestamp without time zone, fim timestamp without time zone, ' +
      'primary key (cod_representante, data))';
    LQuery.ExecSQL;

    LQuery.SQL.Text :=
      'insert into public.representante_km_diario ' +
      '(cod_representante, data, km_rodado, qtd_pontos, qtd_segmentos, inicio, fim) ' +
      'values (:rep, :data, :km, :pontos, :segmentos, :inicio, :fim) ' +
      'on conflict (cod_representante, data) do update set ' +
      'km_rodado = excluded.km_rodado, qtd_pontos = excluded.qtd_pontos, ' +
      'qtd_segmentos = excluded.qtd_segmentos, inicio = excluded.inicio, fim = excluded.fim';
    LQuery.ParamByName('rep').AsInteger := LCodRepresentante;
    LQuery.ParamByName('data').AsDate := ParseApiDate(LData, Date);
    LQuery.ParamByName('km').AsFloat := LKmRodado;
    LQuery.ParamByName('pontos').AsInteger := LQtdPontos;
    LQuery.ParamByName('segmentos').AsInteger := LQtdSegmentos;
    if LInicio <> '' then
      LQuery.ParamByName('inicio').AsDateTime := ParseApiDateTime(LInicio, Now)
    else
      LQuery.ParamByName('inicio').Clear;
    if LFim <> '' then
      LQuery.ParamByName('fim').AsDateTime := ParseApiDateTime(LFim, Now)
    else
      LQuery.ParamByName('fim').Clear;
    LQuery.ExecSQL;
  finally
    LQuery.Free;
  end;

  Result := TJSONObject.Create;
  Result.AddPair('ok', TJSONTrue.Create);
  Result.AddPair('cod_representante', TJSONNumber.Create(LCodRepresentante));
  Result.AddPair('data', LData);
end;
class function TWorbyRepRestDatabase.UpsertClienteVisita(AVisita: TJSONObject): TJSONObject;
var
  LQuery: TFDQuery;
  LCodCliente: Integer;
  LData: string;
  LVendeu: string;
  LValorPedido: Double;
  LStatusVisita: string;
  LStatusRecebido: string;
  LMotivoNVenda: string;
  LDataHora: string;
  LCodRepresentante: Integer;
  LDataValue: TDateTime;
  LDataHoraValue: TDateTime;
  LRowsAffected: LongInt;
  LMotivoStream: TStringStream;
begin
  if not Assigned(AVisita) then
    raise Exception.Create('Objeto de visita e obrigatorio');

  LCodCliente := AVisita.GetValue<Integer>('cod_cliente', 0);
  LData := Trim(AVisita.GetValue<string>('data', ''));
  LVendeu := Trim(AVisita.GetValue<string>('vendeu', 'N'));
  LValorPedido := AVisita.GetValue<Double>('valor_pedido', 0);
  LStatusVisita := Trim(AVisita.GetValue<string>('status_visita', ''));
  LStatusRecebido := LStatusVisita;
  LMotivoNVenda := Trim(AVisita.GetValue<string>('motivo_n_venda', ''));
  LDataHora := Trim(AVisita.GetValue<string>('datahora', ''));
  LCodRepresentante := AVisita.GetValue<Integer>('cod_representante', 0);

  if LCodCliente <= 0 then
    raise Exception.Create('cod_cliente invalido');
  if LDataHora = '' then
    LDataHora := FormatDateTime('yyyy-mm-dd hh:nn:ss', Now);
  if LData = '' then
    LData := Copy(LDataHora, 1, 10);
  if LVendeu = '' then
    LVendeu := 'N';

  if LStatusVisita <> '' then
  begin
    if Pos('PROSPEC', UpperCase(LStatusVisita)) = 1 then
      LStatusVisita := 'PROSPECCAO'
    else if Pos('COBRAN', UpperCase(LStatusVisita)) = 1 then
      LStatusVisita := 'COBRANCA'
    else if Pos('RELACIONAMENTO', UpperCase(LStatusVisita)) = 1 then
      LStatusVisita := 'RELACIONAMENTO'
    else if Pos('POS-VENDA', UpperCase(LStatusVisita)) = 1 then
      LStatusVisita := 'POS-VENDA'
    else if Pos('VISITA IMPOSSIBILITADA', UpperCase(LStatusVisita)) = 1 then
      LStatusVisita := 'VISITA IMPOSSIBILITADA';
    LStatusRecebido := LStatusVisita;
  end;

  if Pos('PROSPEC', UpperCase(LMotivoNVenda)) = 1 then
    LStatusVisita := 'PROSPECCAO'
  else if Pos('COBRAN', UpperCase(LMotivoNVenda)) = 1 then
    LStatusVisita := 'COBRANCA'
  else if Pos('RELACIONAMENTO', UpperCase(LMotivoNVenda)) = 1 then
    LStatusVisita := 'RELACIONAMENTO'
  else if Pos('POS-VENDA', UpperCase(LMotivoNVenda)) = 1 then
    LStatusVisita := 'POS-VENDA'
  else if Pos('VISITA IMPOSSIBILITADA', UpperCase(LMotivoNVenda)) = 1 then
    LStatusVisita := 'VISITA IMPOSSIBILITADA';

  if LStatusVisita <> '' then
    LStatusRecebido := LStatusVisita;

  if LStatusVisita = '' then
  begin
    if SameText(LVendeu, 'S') then
      LStatusVisita := 'Venda'
    else
      LStatusVisita := 'PROXIMIDADE';
  end;
  LogSyncAuditError('cliente_visita fix=20260807_1746 recebido=' + Copy(AVisita.ToJSON, 1, 800) +
    ' | status_final=' + LStatusVisita + ' | motivo=' + Copy(LMotivoNVenda, 1, 120));

  LDataValue := ParseApiDate(LData, Now);
  LDataHoraValue := ParseApiDateTime(LDataHora, Now);

  LQuery := TFDQuery.Create(nil);
  try
    LQuery.Connection := GetConnection;
    LQuery.SQL.Text :=
      'update cliente_visitas set ' +
      'enviado = ''S'', vendeu = :vendeu, motivo_n_venda = :motivo_n_venda, ' +
      'valor_pedido = :valor_pedido, cod_representante = :cod_representante, ' +
      'status_visita = :status_visita ' +
      'where cod_cliente = :cod_cliente and datahora = :datahora';
    LQuery.ParamByName('cod_cliente').AsInteger := LCodCliente;
    LQuery.ParamByName('vendeu').AsString := Copy(LVendeu, 1, 1);
    LQuery.ParamByName('motivo_n_venda').DataType := ftBlob;
    if LMotivoNVenda <> '' then
    begin
      LMotivoStream := TStringStream.Create(LMotivoNVenda, TEncoding.UTF8);
      try
        LQuery.ParamByName('motivo_n_venda').LoadFromStream(LMotivoStream, ftBlob);
      finally
        LMotivoStream.Free;
      end;
    end
    else
      LQuery.ParamByName('motivo_n_venda').Clear;
    LQuery.ParamByName('valor_pedido').AsFloat := LValorPedido;
    LQuery.ParamByName('status_visita').AsString := Copy(LStatusVisita, 1, 40);
    LQuery.ParamByName('datahora').AsDateTime := LDataHoraValue;
    if LCodRepresentante > 0 then
      LQuery.ParamByName('cod_representante').AsInteger := LCodRepresentante
    else
    begin
      LQuery.ParamByName('cod_representante').DataType := ftInteger;
      LQuery.ParamByName('cod_representante').Clear;
    end;
    LQuery.ExecSQL;
    LRowsAffected := LQuery.RowsAffected;

    if LRowsAffected = 0 then
    begin
      LQuery.SQL.Text :=
        'insert into cliente_visitas ' +
        '(cod_cliente, data, vendeu, enviado, motivo_n_venda, valor_pedido, datahora, cod_representante, status_visita) ' +
        'values (:cod_cliente, :data, :vendeu, ''S'', :motivo_n_venda, :valor_pedido, :datahora, :cod_representante, :status_visita)';
      LQuery.ParamByName('cod_cliente').AsInteger := LCodCliente;
      LQuery.ParamByName('data').AsDate := LDataValue;
      LQuery.ParamByName('vendeu').AsString := Copy(LVendeu, 1, 1);
      LQuery.ParamByName('motivo_n_venda').DataType := ftBlob;
      if LMotivoNVenda <> '' then
      begin
        LMotivoStream := TStringStream.Create(LMotivoNVenda, TEncoding.UTF8);
        try
          LQuery.ParamByName('motivo_n_venda').LoadFromStream(LMotivoStream, ftBlob);
        finally
          LMotivoStream.Free;
        end;
      end
      else
        LQuery.ParamByName('motivo_n_venda').Clear;
      LQuery.ParamByName('valor_pedido').AsFloat := LValorPedido;
      LQuery.ParamByName('status_visita').AsString := Copy(LStatusVisita, 1, 40);
      LQuery.ParamByName('datahora').AsDateTime := LDataHoraValue;
      if LCodRepresentante > 0 then
        LQuery.ParamByName('cod_representante').AsInteger := LCodRepresentante
      else
      begin
        LQuery.ParamByName('cod_representante').DataType := ftInteger;
        LQuery.ParamByName('cod_representante').Clear;
      end;
      LQuery.ExecSQL;
    end;

    LQuery.SQL.Text :=
      'update cliente_visitas set status_visita = :status_visita ' +
      'where cod_cliente = :cod_cliente and datahora = :datahora';
    LQuery.ParamByName('cod_cliente').AsInteger := LCodCliente;
    LQuery.ParamByName('datahora').AsDateTime := LDataHoraValue;
    LQuery.ParamByName('status_visita').AsString := Copy(LStatusVisita, 1, 40);
    LQuery.ExecSQL;
  finally
    LQuery.Free;
  end;

  Result := TJSONObject.Create;
  Result.AddPair('ok', TJSONTrue.Create);
  Result.AddPair('status_visita', LStatusVisita);
end;

class function TWorbyRepRestDatabase.QueryToJsonArray(AQuery: TFDQuery): TJSONArray;
var
  LItem: TJSONObject;
  LField: TField;
  LStream: TBytesStream;
  LBytes: TBytes;
begin
  Result := TJSONArray.Create;
  AQuery.First;
  while not AQuery.Eof do
  begin
    LItem := TJSONObject.Create;
    for LField in AQuery.Fields do
    begin
      if LField.DataType in [ftBlob, ftMemo, ftWideMemo] then
      begin
        if SameText(LField.FieldName, 'imagem_bd') then
        begin
          if LField.IsNull then
            LItem.AddPair(LField.FieldName, TJSONNull.Create)
          else
          begin
            LStream := TBytesStream.Create;
            try
              TBlobField(LField).SaveToStream(LStream);
              LBytes := LStream.Bytes;
              SetLength(LBytes, LStream.Size);
            finally
              LStream.Free;
            end;
            LItem.AddPair(LField.FieldName, TJSONString.Create(TNetEncoding.Base64.EncodeBytesToString(LBytes)));
          end;
        end;
        Continue;
      end;
      LItem.AddPair(LField.FieldName, FieldValueToJson(LField));
    end;
    Result.AddElement(LItem);
    AQuery.Next;
  end;
end;

class function TWorbyRepRestDatabase.QueryRowToJson(AQuery: TFDQuery;
  const AIgnoreFields: array of string): TJSONObject;
var
  LField: TField;
  LIgnore: string;
  LIgnored: Boolean;
begin
  Result := nil;
  if AQuery.IsEmpty then
    Exit;

  AQuery.First;
  Result := TJSONObject.Create;
  for LField in AQuery.Fields do
  begin
    LIgnored := False;
    for LIgnore in AIgnoreFields do
    begin
      if SameText(LField.FieldName, LIgnore) then
      begin
        LIgnored := True;
        Break;
      end;
    end;

    if not LIgnored then
      Result.AddPair(LField.FieldName, FieldValueToJson(LField));
  end;
end;

initialization
  GGeoProgressLock := TCriticalSection.Create;

finalization
  GGeoProgressLock.Free;

end.
