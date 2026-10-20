unit WorbyRepRest.Metadata;

interface

uses
  System.SysUtils;

type
  TTableKeyType = (tktString, tktInteger);

  TTableInfo = record
    Name: string;
    PrimaryKey: string;
    PrimaryKeyType: TTableKeyType;
    RepresentativeField: string;
    RepresentativeFieldType: TTableKeyType;
  end;

  TWorbyRepRestMetadata = class
  private
    class function NewTable(const AName, APrimaryKey: string;
      APrimaryKeyType: TTableKeyType; const ARepresentativeField: string = '';
      ARepresentativeFieldType: TTableKeyType = tktInteger): TTableInfo; static;
  public
    class function Tables: TArray<TTableInfo>;
    class function TryGetTable(const ATableName: string; out AInfo: TTableInfo): Boolean;
  end;

implementation

class function TWorbyRepRestMetadata.NewTable(const AName, APrimaryKey: string;
  APrimaryKeyType: TTableKeyType; const ARepresentativeField: string;
  ARepresentativeFieldType: TTableKeyType): TTableInfo;
begin
  Result.Name := AName;
  Result.PrimaryKey := APrimaryKey;
  Result.PrimaryKeyType := APrimaryKeyType;
  Result.RepresentativeField := ARepresentativeField;
  Result.RepresentativeFieldType := ARepresentativeFieldType;
end;

class function TWorbyRepRestMetadata.Tables: TArray<TTableInfo>;
begin
  Result := [
    NewTable('representante', 'id', tktInteger),
    NewTable('cliente', 'cod_cliente', tktInteger, 'id_representante', tktInteger),
    NewTable('cidades', 'cod_cidade', tktInteger),
    NewTable('vendas1', 'numdoc', tktInteger, 'id_representante', tktInteger),
    NewTable('vendas2', 'numdoc', tktInteger, 'id_representante', tktInteger),
    NewTable('cr1', 'titulo', tktString),
    NewTable('produto', 'cod_produto', tktInteger),
    NewTable('subcategoria', 'id', tktInteger),
    NewTable('grupo', 'cod_grupo', tktInteger),
    NewTable('produto_representante', 'cod_produto', tktInteger, 'id_representante', tktInteger),
    NewTable('grupo_representante', 'cod_grupo', tktInteger, 'id_representante', tktInteger),
    NewTable('produto_representante_inativos', 'cod_produto', tktInteger, 'id_representante', tktInteger),
    NewTable('grade_comissao', 'tipo', tktInteger),
    NewTable('escala_comissao', 'desconto', tktString),
    NewTable('fop', 'cod_fop', tktInteger),
    NewTable('fop_prazo', 'cod_fop', tktInteger),
    NewTable('prazo', 'id', tktInteger),
    NewTable('prazo_representante', 'id_prazo', tktInteger, 'id_representante', tktInteger),
    NewTable('processo_pedido', 'id', tktInteger),
    NewTable('hist_processo_pedido', 'processo_id', tktInteger),
    NewTable('v_comissao_nova', 'numdoc', tktInteger)
  ];
end;

class function TWorbyRepRestMetadata.TryGetTable(const ATableName: string;
  out AInfo: TTableInfo): Boolean;
var
  LItem: TTableInfo;
begin
  for LItem in Tables do
  begin
    if SameText(LItem.Name, ATableName) then
    begin
      AInfo := LItem;
      Exit(True);
    end;
  end;

  Result := False;
end;

end.
