unit WorbyRepRest.Controllers.Tables;

interface

type
  TWorbyRepRestTablesController = class
  public
    class procedure RegisterRoutes;
  end;

implementation

uses
  System.Classes,
  System.JSON,
  System.NetEncoding,
  System.SysUtils,
  System.ZLib,
  Horse,
  WorbyRepRest.Database,
  WorbyRepRest.Metadata;

function JsonError(const AMessage: string): string;
begin
  Result := '{"error":"' + StringReplace(AMessage, '"', '\"', [rfReplaceAll]) + '"}';
end;

function BuildTablesJson: string;
var
  LArray: TJSONArray;
  LItem: TTableInfo;
  LJson: TJSONObject;
begin
  LArray := TJSONArray.Create;
  try
    for LItem in TWorbyRepRestMetadata.Tables do
    begin
      LJson := TJSONObject.Create;
      LJson.AddPair('table', LItem.Name);
      LJson.AddPair('primaryKey', LItem.PrimaryKey);
      LJson.AddPair('representativeField', LItem.RepresentativeField);
      LArray.AddElement(LJson);
    end;

    Result := LArray.ToJSON;
  finally
    LArray.Free;
  end;
end;

function JsonBodyString(AObj: TJSONObject; const AName: string): string;
var
  LValue: TJSONValue;
begin
  Result := '';
  if not Assigned(AObj) then
    Exit;
  LValue := AObj.GetValue(AName);
  if Assigned(LValue) and not (LValue is TJSONNull) then
    Result := Trim(LValue.Value);
end;

function CompressStringToBase64(const AText: string): string;
var
  LInputBytes: TBytes;
  LCompressedBytes: TBytes;
  LOutput: TBytesStream;
  LCompressor: TCompressionStream;
begin
  LInputBytes := TEncoding.UTF8.GetBytes(AText);
  LOutput := TBytesStream.Create;
  try
    LCompressor := TCompressionStream.Create(clMax, LOutput);
    try
      if Length(LInputBytes) > 0 then
        LCompressor.WriteBuffer(LInputBytes[0], Length(LInputBytes));
    finally
      LCompressor.Free;
    end;

    SetLength(LCompressedBytes, LOutput.Size);
    if LOutput.Size > 0 then
      Move(LOutput.Bytes[0], LCompressedBytes[0], LOutput.Size);
    Result := TNetEncoding.Base64.EncodeBytesToString(LCompressedBytes);
  finally
    LOutput.Free;
  end;
end;
function ParseRequestBody(Req: THorseRequest): TJSONObject;
var
  LValue: TJSONValue;
begin
  Result := nil;
  LValue := TJSONObject.ParseJSONValue(Req.Body);
  if not Assigned(LValue) then
    Exit;

  if LValue is TJSONObject then
    Result := TJSONObject(LValue)
  else
    LValue.Free;
end;

class procedure TWorbyRepRestTablesController.RegisterRoutes;
begin
  THorse.Get('/health',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Status(200).ContentType('application/json').Send('{"status":"ok"}');
    end);

  THorse.Get('/tables',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Status(200).ContentType('application/json').Send(BuildTablesJson);
    end);

  THorse.Post('/tables',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LBody: TJSONObject;
    begin
      LBody := ParseRequestBody(Req);
      try
        if not Assigned(LBody) then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Body JSON invalido'));
          Exit;
        end;

        Res.Status(200).ContentType('application/json').Send(BuildTablesJson);
      finally
        LBody.Free;
      end;
    end);

  THorse.Post('/api/count',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LBody: TJSONObject;
      LTableName: string;
      LCodRepresentante: string;
      LCodCliente: string;
      LDataUltSincronizacao: string;
      LFilterValue: string;
      LTable: TTableInfo;
      LJson: TJSONObject;
      LTotal: Integer;
    begin
      LBody := ParseRequestBody(Req);
      try
        if not Assigned(LBody) then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Body JSON invalido'));
          Exit;
        end;

        LTableName := LBody.GetValue<string>('table', '');
        if LTableName = '' then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Campo table e obrigatorio'));
          Exit;
        end;

        if not TWorbyRepRestMetadata.TryGetTable(LTableName, LTable) then
        begin
          Res.Status(404).ContentType('application/json').Send(JsonError('Tabela nao mapeada'));
          Exit;
        end;

        LCodRepresentante := JsonBodyString(LBody, 'codRepresentante');
        LCodCliente := LBody.GetValue<string>('codCliente', '');
        LDataUltSincronizacao := LBody.GetValue<string>('dataUltSincronizacao', '');
        LFilterValue := LCodRepresentante;
        if (LCodCliente <> '') and (SameText(LTableName, 'vendas1') or SameText(LTableName, 'vendas2')) then
          LFilterValue := LCodCliente;

        LTotal := TWorbyRepRestDatabase.CountTable(LTable, LFilterValue, LDataUltSincronizacao);
        LJson := TJSONObject.Create;
        try
          LJson.AddPair('total', TJSONNumber.Create(LTotal));
          Res.Status(200).ContentType('application/json').Send(LJson.ToJSON);
        finally
          LJson.Free;
        end;
      finally
        LBody.Free;
      end;
    end);

  THorse.Post('/api/list',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LBody: TJSONObject;
      LTableName: string;
      LLimit: Integer;
      LOffset: Integer;
      LCodRepresentante: string;
      LCodCliente: string;
      LDataUltSincronizacao: string;
      LNumDocsCsv: string;
      LNumDocsVal: TJSONValue;
      LNumDocsArr: TJSONArray;
      LNumItem: TJSONValue;
      LNumInt: Int64;
      LFilterValue: string;
      LTable: TTableInfo;
      LJson: TJSONArray;
      I: Integer;
    begin
      LBody := ParseRequestBody(Req);
      try
        if not Assigned(LBody) then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Body JSON invalido'));
          Exit;
        end;

        LTableName := LBody.GetValue<string>('table', '');
        if LTableName = '' then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Campo table e obrigatorio'));
          Exit;
        end;

        if not TWorbyRepRestMetadata.TryGetTable(LTableName, LTable) then
        begin
          Res.Status(404).ContentType('application/json').Send(JsonError('Tabela nao mapeada'));
          Exit;
        end;

        LLimit := LBody.GetValue<Integer>('limit', 300);
        LOffset := LBody.GetValue<Integer>('offset', 0);
        LCodRepresentante := JsonBodyString(LBody, 'codRepresentante');
        TWorbyRepRestDatabase.RegistrarSincronizacaoRepresentante(LCodRepresentante, 'api/list');
        LCodCliente := LBody.GetValue<string>('codCliente', '');
        LDataUltSincronizacao := LBody.GetValue<string>('dataUltSincronizacao', '');
        LNumDocsCsv := '';
        if SameText(LTableName, 'vendas2') then
        begin
          LNumDocsVal := LBody.GetValue('numdocs');
          if LNumDocsVal is TJSONArray then
          begin
            LNumDocsArr := TJSONArray(LNumDocsVal);
            for I := 0 to LNumDocsArr.Count - 1 do
            begin
              LNumItem := LNumDocsArr.Items[I];
              if not TryStrToInt64(Trim(LNumItem.Value), LNumInt) then
                Continue;
              if LNumDocsCsv <> '' then
                LNumDocsCsv := LNumDocsCsv + ',';
              LNumDocsCsv := LNumDocsCsv + IntToStr(LNumInt);
            end;
            if LNumDocsCsv = '' then
              LNumDocsCsv := '0';
          end;
        end;
        LFilterValue := LCodRepresentante;
        if (LCodCliente <> '') and (SameText(LTableName, 'vendas1') or SameText(LTableName, 'vendas2')) then
          LFilterValue := LCodCliente;

        LJson := TWorbyRepRestDatabase.ListTable(LTable, LLimit, LOffset, LFilterValue, LDataUltSincronizacao, LNumDocsCsv);
        try
          Res.Status(200).ContentType('application/json').Send(LJson.ToJSON);
        finally
          LJson.Free;
        end;
      finally
        LBody.Free;
      end;
    end);

  THorse.Post('/api/dashboard/meta',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LBody: TJSONObject;
      LCodRepresentante: Integer;
      LMes: string;
      LStatus: string;
      LDiaInicial: Integer;
      LDiaFinal: Integer;
      LBusca: string;
      LJson: TJSONObject;
    begin
      LBody := ParseRequestBody(Req);
      try
        if not Assigned(LBody) then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Body JSON invalido'));
          Exit;
        end;

        LCodRepresentante := LBody.GetValue<Integer>('codRepresentante', 0);
        if LCodRepresentante <= 0 then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Campo codRepresentante e obrigatorio'));
          Exit;
        end;

        LMes := Trim(LBody.GetValue<string>('mes', ''));
        if LMes = '' then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Campo mes e obrigatorio'));
          Exit;
        end;

        LJson := TWorbyRepRestDatabase.GetMetaRepresentante(LCodRepresentante, LMes);
        try
          Res.Status(200).ContentType('application/json').Send(LJson.ToJSON);
        finally
          LJson.Free;
        end;
      finally
        LBody.Free;
      end;
    end);

  THorse.Post('/api/dashboard/meses',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LBody: TJSONObject;
      LCodRepresentante: Integer;
      LJson: TJSONArray;
    begin
      LBody := ParseRequestBody(Req);
      try
        if not Assigned(LBody) then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Body JSON invalido'));
          Exit;
        end;

        LCodRepresentante := LBody.GetValue<Integer>('codRepresentante', 0);
        if LCodRepresentante <= 0 then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Campo codRepresentante e obrigatorio'));
          Exit;
        end;

        LJson := TWorbyRepRestDatabase.GetMesesDashboard(LCodRepresentante);
        try
          Res.Status(200).ContentType('application/json').Send(LJson.ToJSON);
        finally
          LJson.Free;
        end;
      finally
        LBody.Free;
      end;
    end);

  THorse.Post('/api/dashboard/pedidos_faturados',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LBody: TJSONObject;
      LCodRepresentante: Integer;
      LMes: string;
      LStatus: string;
      LDiaInicial: Integer;
      LDiaFinal: Integer;
      LBusca: string;
      LJson: TJSONObject;
    begin
      LBody := ParseRequestBody(Req);
      try
        if not Assigned(LBody) then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Body JSON invalido'));
          Exit;
        end;

        LCodRepresentante := LBody.GetValue<Integer>('codRepresentante', 0);
        if LCodRepresentante <= 0 then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Campo codRepresentante e obrigatorio'));
          Exit;
        end;

        LMes := Trim(LBody.GetValue<string>('mes', ''));
        if LMes = '' then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Campo mes e obrigatorio'));
          Exit;
        end;

        LStatus := Trim(LBody.GetValue<string>('status', 'FATURADO'));
        LDiaInicial := LBody.GetValue<Integer>('diaInicial', 0);
        LDiaFinal := LBody.GetValue<Integer>('diaFinal', 0);
        LBusca := Trim(LBody.GetValue<string>('busca', ''));

        LJson := TWorbyRepRestDatabase.GetPedidosFaturadosDashboard(
          LCodRepresentante,
          LMes,
          LStatus,
          LDiaInicial,
          LDiaFinal,
          LBusca
        );
        try
          Res.Status(200).ContentType('application/json').Send(LJson.ToJSON);
        finally
          LJson.Free;
        end;
      finally
        LBody.Free;
      end;
    end);

  THorse.Post('/api/cliente/documento',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LBody: TJSONObject;
      LDocumento: string;
      LJson: TJSONObject;
    begin
      LBody := ParseRequestBody(Req);
      try
        if not Assigned(LBody) then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Body JSON invalido'));
          Exit;
        end;

        LDocumento := LBody.GetValue<string>('documento', '');
        if Trim(LDocumento) = '' then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Campo documento e obrigatorio'));
          Exit;
        end;

        LJson := TWorbyRepRestDatabase.GetClienteByDocumento(LDocumento);
        try
          if not Assigned(LJson) then
          begin
            Res.Status(404).ContentType('application/json').Send(JsonError('Cliente nao encontrado'));
            Exit;
          end;

          Res.Status(200).ContentType('application/json').Send(LJson.ToJSON);
        finally
          LJson.Free;
        end;
      finally
        LBody.Free;
      end;

    end);

  THorse.Post('/api/cliente',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LBody: TJSONObject;
      LJson: TJSONObject;
    begin
      LBody := ParseRequestBody(Req);
      try
        if not Assigned(LBody) then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Body JSON invalido'));
          Exit;
        end;

        LJson := TWorbyRepRestDatabase.UpsertCliente(LBody);
        try
          Res.Status(200).ContentType('application/json').Send(LJson.ToJSON);
        finally
          LJson.Free;
        end;
      finally
        LBody.Free;
      end;
    end);

  THorse.Post('/api/geolocalizacao',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LBody: TJSONObject;
      LJson: TJSONObject;
    begin
      LBody := ParseRequestBody(Req);
      try
        if not Assigned(LBody) then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Body JSON invalido'));
          Exit;
        end;

        LJson := TWorbyRepRestDatabase.InsertRepresentanteLocalizacao(LBody);
        try
          Res.Status(200).ContentType('application/json').Send(LJson.ToJSON);
        finally
          LJson.Free;
        end;
      finally
        LBody.Free;
      end;
    end);

  THorse.Post('/api/representante_km_diario',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LBody: TJSONObject;
      LJson: TJSONObject;
    begin
      LBody := ParseRequestBody(Req);
      try
        if not Assigned(LBody) then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Body JSON invalido'));
          Exit;
        end;

        LJson := TWorbyRepRestDatabase.UpsertRepresentanteKmDiario(LBody);
        try
          Res.Status(200).ContentType('application/json').Send(LJson.ToJSON);
        finally
          LJson.Free;
        end;
      finally
        LBody.Free;
      end;
    end);
  THorse.Post('/api/cliente_visita',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LBody: TJSONObject;
      LJson: TJSONObject;
    begin
      LBody := ParseRequestBody(Req);
      try
        if not Assigned(LBody) then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Body JSON invalido'));
          Exit;
        end;

        LJson := TWorbyRepRestDatabase.UpsertClienteVisita(LBody);
        try
          Res.Status(200).ContentType('application/json').Send(LJson.ToJSON);
        finally
          LJson.Free;
        end;
      finally
        LBody.Free;
      end;
    end);

  THorse.Post('/api/representante/sqlite_backup/save',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LBody: TJSONObject;
      LAuth: TJSONObject;
      LJson: TJSONObject;
      LCodRepresentante: Integer;
      LAuthRepresentante: Integer;
      LLogin: string;
      LSenha: string;
    begin
      LBody := ParseRequestBody(Req);
      try
        if not Assigned(LBody) then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Body JSON invalido'));
          Exit;
        end;

        LCodRepresentante := LBody.GetValue<Integer>('cod_representante', 0);
        LLogin := JsonBodyString(LBody, 'login');
        LSenha := JsonBodyString(LBody, 'senha');
        if (LCodRepresentante <= 0) or (LLogin = '') or (LSenha = '') then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('cod_representante, login e senha sao obrigatorios'));
          Exit;
        end;

        LAuth := TWorbyRepRestDatabase.LoginTbusu(LLogin, LSenha);
        try
          if not Assigned(LAuth) then
          begin
            Res.Status(401).ContentType('application/json').Send(JsonError('Usuario ou senha invalidos'));
            Exit;
          end;
          LAuthRepresentante := LAuth.GetValue<Integer>('cod_representante', 0);
          if LAuthRepresentante <> LCodRepresentante then
          begin
            Res.Status(403).ContentType('application/json').Send(JsonError('Representante nao autorizado para este backup'));
            Exit;
          end;
        finally
          LAuth.Free;
        end;

        LJson := TWorbyRepRestDatabase.SaveRepresentanteSqliteBackup(LBody);
        try
          Res.Status(200).ContentType('application/json').Send(LJson.ToJSON);
        finally
          LJson.Free;
        end;
      finally
        LBody.Free;
      end;
    end);

  THorse.Post('/api/representante/sqlite_backup/get',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LBody: TJSONObject;
      LAuth: TJSONObject;
      LJson: TJSONObject;
      LCodRepresentante: Integer;
      LAuthRepresentante: Integer;
      LLogin: string;
      LSenha: string;
    begin
      LBody := ParseRequestBody(Req);
      try
        if not Assigned(LBody) then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Body JSON invalido'));
          Exit;
        end;

        LCodRepresentante := LBody.GetValue<Integer>('cod_representante', 0);
        if LCodRepresentante <= 0 then
          LCodRepresentante := StrToIntDef(JsonBodyString(LBody, 'codRepresentante'), 0);
        LLogin := JsonBodyString(LBody, 'login');
        LSenha := JsonBodyString(LBody, 'senha');
        if (LCodRepresentante <= 0) or (LLogin = '') or (LSenha = '') then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('cod_representante, login e senha sao obrigatorios'));
          Exit;
        end;

        LAuth := TWorbyRepRestDatabase.LoginTbusu(LLogin, LSenha);
        try
          if not Assigned(LAuth) then
          begin
            Res.Status(401).ContentType('application/json').Send(JsonError('Usuario ou senha invalidos'));
            Exit;
          end;
          LAuthRepresentante := LAuth.GetValue<Integer>('cod_representante', 0);
          if LAuthRepresentante <> LCodRepresentante then
          begin
            Res.Status(403).ContentType('application/json').Send(JsonError('Representante nao autorizado para este backup'));
            Exit;
          end;
        finally
          LAuth.Free;
        end;

        LJson := TWorbyRepRestDatabase.GetRepresentanteSqliteBackup(LCodRepresentante);
        try
          Res.Status(200).ContentType('application/json').Send(LJson.ToJSON);
        finally
          LJson.Free;
        end;
      finally
        LBody.Free;
      end;
    end);
  THorse.Post('/api/sync_all',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LBody: TJSONObject;
      LTablesValue: TJSONValue;
      LTablesArray: TJSONArray;
      LTableName: string;
      LCodRepresentante: string;
      LVersao: string;
      LTable: TTableInfo;
      LJson: TJSONArray;
      LResult: TJSONObject;
      I: Integer;
      LItem: TJSONValue;
      LDefaultTables: array[0..14] of string;
      LDefaultName: string;
    begin
      LBody := ParseRequestBody(Req);
      try
        if not Assigned(LBody) then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Body JSON invalido'));
          Exit;
        end;

        LCodRepresentante := JsonBodyString(LBody, 'codRepresentante');
        LVersao := JsonBodyString(LBody, 'versao');
        TWorbyRepRestDatabase.RegistrarSincronizacaoRepresentante(LCodRepresentante, 'api/sync_all', LVersao);
        LTablesValue := LBody.GetValue('tables');

        if LTablesValue is TJSONArray then
          LTablesArray := TJSONArray(LTablesValue)
        else
          LTablesArray := nil;

        LDefaultTables[0] := 'representante';
        LDefaultTables[1] := 'cliente';
        LDefaultTables[2] := 'vendas1';
        LDefaultTables[3] := 'vendas2';
        LDefaultTables[4] := 'produto';
        LDefaultTables[5] := 'subcategoria';
        LDefaultTables[6] := 'fop';
        LDefaultTables[7] := 'fop_prazo';
        LDefaultTables[8] := 'prazo';
        LDefaultTables[9] := 'cidades';
        LDefaultTables[10] := 'produto_representante';
        LDefaultTables[11] := 'grupo_representante';
        LDefaultTables[12] := 'produto_representante_inativos';
        LDefaultTables[13] := 'prazo_representante';
        LDefaultTables[14] := 'cr1';

        LResult := TJSONObject.Create;
        try
          if Assigned(LTablesArray) then
          begin
            for I := 0 to LTablesArray.Count - 1 do
            begin
              LItem := LTablesArray.Items[I];
              if not (LItem is TJSONString) then
                continue;
              LTableName := TJSONString(LItem).Value;

              if not TWorbyRepRestMetadata.TryGetTable(LTableName, LTable) then
              begin
                Res.Status(404).ContentType('application/json').Send(JsonError('Tabela nao mapeada: ' + LTableName));
                Exit;
              end;

              LJson := TWorbyRepRestDatabase.ListTable(LTable, 0, 0, LCodRepresentante);
              LResult.AddPair(LTableName, LJson);
            end;
          end
          else
          begin
            for LDefaultName in LDefaultTables do
            begin
              if not TWorbyRepRestMetadata.TryGetTable(LDefaultName, LTable) then
                continue;
              LJson := TWorbyRepRestDatabase.ListTable(LTable, 0, 0, LCodRepresentante);
              LResult.AddPair(LDefaultName, LJson);
            end;
          end;

          Res.Status(200).ContentType('application/json').Send(LResult.ToJSON);
        finally
          LResult.Free;
        end;
      finally
        LBody.Free;
      end;
    end);

  THorse.Post('/api/geocode_progress',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LBody: TJSONObject;
      LProgress: TJSONObject;
      LCodRepresentante: string;
    begin
      LBody := ParseRequestBody(Req);
      try
        if not Assigned(LBody) then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Body JSON invalido'));
          Exit;
        end;
        LCodRepresentante := JsonBodyString(LBody, 'codRepresentante');
        LProgress := TWorbyRepRestDatabase.GetGeocodeProgress(LCodRepresentante);
        try
          Res.Status(200).ContentType('application/json').Send(LProgress.ToJSON);
        finally
          LProgress.Free;
        end;
      finally
        LBody.Free;
      end;
    end);

  THorse.Post('/api/sync_script',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LBody: TJSONObject;
      LTablesValue: TJSONValue;
      LSchemaValue: TJSONValue;
      LDataUltValue: TJSONValue;
      LCodRepresentante: string;
      LVersao: string;
      LEncoding: string;
      LScriptValue: TJSONValue;
      LScriptText: string;
      LPair: TJSONPair;
      LResult: TJSONObject;
    begin
      LBody := ParseRequestBody(Req);
      try
        if not Assigned(LBody) then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Body JSON invalido'));
          Exit;
        end;

        LCodRepresentante := JsonBodyString(LBody, 'codRepresentante');
        LVersao := JsonBodyString(LBody, 'versao');
        LEncoding := JsonBodyString(LBody, 'scriptEncoding');
        TWorbyRepRestDatabase.RegistrarSincronizacaoRepresentante(LCodRepresentante, 'api/sync_script', LVersao);
        LTablesValue := LBody.GetValue('tables');
        LSchemaValue := LBody.GetValue('schema');
        LDataUltValue := LBody.GetValue('dataUltSincronizacao');

        if not (LTablesValue is TJSONArray) then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Campo tables deve ser um array'));
          Exit;
        end;

        if not (LSchemaValue is TJSONObject) then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Campo schema deve ser um objeto'));
          Exit;
        end;

        if not (LDataUltValue is TJSONObject) then
          LDataUltValue := nil;

        LResult := TWorbyRepRestDatabase.BuildSyncScript(
          LCodRepresentante,
          TJSONArray(LTablesValue),
          TJSONObject(LSchemaValue),
          TJSONObject(LDataUltValue),
          LVersao
        );
        try
          if SameText(LEncoding, 'zlib-base64') then
          begin
            LScriptValue := LResult.GetValue('script');
            if Assigned(LScriptValue) then
            begin
              LScriptText := LScriptValue.Value;
              LPair := LResult.RemovePair('script');
              if Assigned(LPair) then
                LPair.Free;
              LResult.AddPair('scriptEncoding', 'zlib-base64');
              LResult.AddPair('scriptOriginalBytes', TJSONNumber.Create(TEncoding.UTF8.GetByteCount(LScriptText)));
              LResult.AddPair('scriptZlib', CompressStringToBase64(LScriptText));
            end;
          end;

          Res.Status(200).ContentType('application/json').Send(LResult.ToJSON);
        finally
          LResult.Free;
        end;
      finally
        LBody.Free;
      end;
    end);

  THorse.Post('/api/item',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LBody: TJSONObject;
      LTableName: string;
      LId: string;
      LTable: TTableInfo;
      LJson: TJSONObject;
    begin
      LBody := ParseRequestBody(Req);
      try
        if not Assigned(LBody) then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Body JSON invalido'));
          Exit;
        end;

        LTableName := LBody.GetValue<string>('table', '');
        LId := LBody.GetValue<string>('id', '');

        if LTableName = '' then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Campo table e obrigatorio'));
          Exit;
        end;

        if LId = '' then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Campo id e obrigatorio'));
          Exit;
        end;

        if not TWorbyRepRestMetadata.TryGetTable(LTableName, LTable) then
        begin
          Res.Status(404).ContentType('application/json').Send(JsonError('Tabela nao mapeada'));
          Exit;
        end;

        LJson := TWorbyRepRestDatabase.GetById(
          LTable.Name,
          LTable.PrimaryKey,
          LTable.PrimaryKeyType,
          LId
        );
        try
          if not Assigned(LJson) then
          begin
            Res.Status(404).ContentType('application/json').Send(JsonError('Registro nao encontrado'));
            Exit;
          end;

          Res.Status(200).ContentType('application/json').Send(LJson.ToJSON);
        finally
          LJson.Free;
        end;
      finally
        LBody.Free;
      end;
    end);

  THorse.Post('/login',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LBody: TJSONObject;
      LLogin: string;
      LSenha: string;
      LUsuario: TJSONObject;
      LResponse: TJSONObject;
    begin
      LBody := ParseRequestBody(Req);
      try
        if not Assigned(LBody) then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Body JSON invalido'));
          Exit;
        end;

        LLogin := LBody.GetValue<string>('login', '');
        LSenha := LBody.GetValue<string>('senha', '');

        if LLogin = '' then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Campo login e obrigatorio'));
          Exit;
        end;

        if LSenha = '' then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Campo senha e obrigatorio'));
          Exit;
        end;

        LUsuario := TWorbyRepRestDatabase.LoginTbusu(LLogin, LSenha);
        try
          if not Assigned(LUsuario) then
          begin
            Res.Status(401).ContentType('application/json').Send(JsonError('Usuario ou senha invalidos'));
            Exit;
          end;

          LResponse := TJSONObject.Create;
          try
            LResponse.AddPair('success', TJSONTrue.Create);
            LResponse.AddPair('user', LUsuario.Clone as TJSONValue);
            Res.Status(200).ContentType('application/json').Send(LResponse.ToJSON);
          finally
            LResponse.Free;
          end;
        finally
          LUsuario.Free;
        end;
      finally
        LBody.Free;
      end;
    end);

  THorse.Post('/api/pedido',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LBody: TJSONObject;
      LVendas1Value: TJSONValue;
      LVendas2Value: TJSONValue;
      LResponse: TJSONObject;
    begin
      LBody := ParseRequestBody(Req);
      try
        if not Assigned(LBody) then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Body JSON invalido'));
          Exit;
        end;

        LVendas1Value := LBody.GetValue('vendas1');
        LVendas2Value := LBody.GetValue('vendas2');

        if not (LVendas1Value is TJSONObject) then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Campo vendas1 deve ser um objeto JSON'));
          Exit;
        end;

        if not (LVendas2Value is TJSONArray) then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Campo vendas2 deve ser um array JSON'));
          Exit;
        end;

        LResponse := TWorbyRepRestDatabase.InsertPedido(
          TJSONObject(LVendas1Value),
          TJSONArray(LVendas2Value)
        );
        try
          Res.Status(201).ContentType('application/json').Send(LResponse.ToJSON);
        finally
          LResponse.Free;
        end;
      finally
        LBody.Free;
      end;
    end);

  THorse.Post('/api/pedidos_digitados',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LBody: TJSONObject;
      LPedidosValue: TJSONValue;
      LPedidos: TJSONArray;
      LPedidoUnico: TJSONObject;
      LResponse: TJSONObject;
      LVendas1Value: TJSONValue;
      LVendas2Value: TJSONValue;
      LCodRepresentante: string;
    begin
      LBody := ParseRequestBody(Req);
      try
        if not Assigned(LBody) then
        begin
          Res.Status(400).ContentType('application/json').Send(JsonError('Body JSON invalido'));
          Exit;
        end;

        LPedidosValue := LBody.GetValue('pedidos');
        LPedidos := nil;

        if LPedidosValue is TJSONArray then
          LPedidos := TJSONArray(LPedidosValue)
        else
        begin
          // compatibilidade: aceita payload de pedido unico no mesmo formato de /api/pedido
          LVendas1Value := LBody.GetValue('vendas1');
          LVendas2Value := LBody.GetValue('vendas2');
          if Assigned(LVendas1Value) and Assigned(LVendas2Value) then
          begin
            LPedidos := TJSONArray.Create;
            LPedidoUnico := TJSONObject.Create;
            LPedidoUnico.AddPair('vendas1', LVendas1Value.Clone as TJSONValue);
            LPedidoUnico.AddPair('vendas2', LVendas2Value.Clone as TJSONValue);
            LPedidos.AddElement(LPedidoUnico);
          end;
        end;

        if not Assigned(LPedidos) then
        begin
          Res.Status(400).ContentType('application/json').Send(
            JsonError('Informe "pedidos" (array) ou "vendas1"+"vendas2"')
          );
          Exit;
        end;

        LCodRepresentante := Trim(JsonBodyString(LBody, 'codRepresentante'));

        try
          LResponse := TWorbyRepRestDatabase.InsertPedidosDigitados(LPedidos, LCodRepresentante);
          try
            Res.Status(200).ContentType('application/json').Send(LResponse.ToJSON);
          finally
            LResponse.Free;
          end;
        finally
          // so libera se foi criado localmente (pedido unico)
          if not (LPedidosValue is TJSONArray) then
            LPedidos.Free;
        end;
      finally
        LBody.Free;
      end;
    end);
end;

end.
