unit UUSDBClient;

{$MODE Delphi}

interface

uses Classes;

type
  TUSDBEntry = record
    ID, Year: integer;
    Artist, Title, Status, Chart: UTF8String;
    Ready: boolean;
  end;
  TUSDBEntries = array of TUSDBEntry;

  TUSDBRequest = class(TThread)
  private
    FQuery: UTF8String;
    FOffset, FDownloadID: integer;
  protected
    procedure Execute; override;
  public
    Body, ErrorText: UTF8String;
    Query: UTF8String;
    Offset, DownloadID, Revision: integer;
    constructor Create(const AQuery: UTF8String; AOffset: integer; ADownloadID: integer = 0);
  end;

function DecodeUSDBResults(const Body: UTF8String; out Entries: TUSDBEntries; out Total: integer; out ErrorText: UTF8String): boolean;

implementation

uses SysUtils, fphttpclient, fpjson, jsonparser, UPath, UPlatform;

function EncodeQuery(const Value: UTF8String): string;
var I: integer;
begin
  Result := '';
  for I := 1 to Length(Value) do
    if Value[I] in ['a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.', '~'] then
      Result := Result + Value[I]
    else
      Result := Result + '%' + IntToHex(Ord(Value[I]), 2);
end;

constructor TUSDBRequest.Create(const AQuery: UTF8String; AOffset: integer; ADownloadID: integer);
begin
  inherited Create(true);
  FreeOnTerminate := false;
  FQuery := AQuery;
  FOffset := AOffset;
  FDownloadID := ADownloadID;
  Query := AQuery;
  Offset := AOffset;
  DownloadID := ADownloadID;
  Start;
end;

procedure TUSDBRequest.Execute;
var
  Config: TUnicodeMemIniFile;
  ConfigPath: IPath;
  Client: TFPHTTPClient;
  Response: TStringStream;
  URL, Token, Method: string;
begin
  Client := nil;
  Response := nil;
  try
    ConfigPath := Platform.GetGameUserPath.Append('usdb-bridge.ini');
    if GetEnvironmentVariable('USDX_USDB_BRIDGE') <> '' then
      ConfigPath := Path(GetEnvironmentVariable('USDX_USDB_BRIDGE'));
    if not ConfigPath.IsFile then
      raise Exception.Create('USDB_BROWSER_OPEN_SYNCER');
    Config := TUnicodeMemIniFile.Create(ConfigPath, true);
    try
      URL := Config.ReadString('Bridge', 'URL', '');
      Token := Config.ReadString('Bridge', 'Token', '');
    finally
      Config.Free;
    end;
    if (Pos('http://127.0.0.1:', URL) <> 1) or (Token = '') then
      raise Exception.Create('USDB_BROWSER_OPEN_SYNCER');
    Client := TFPHTTPClient.Create(nil);
    Client.ConnectTimeout := 1000;
    Client.IOTimeout := 5000;
    Client.AddHeader('X-USDX-Token', Token);
    Response := TStringStream.Create('');
    if FDownloadID > 0 then
    begin
      Method := 'POST';
      URL := URL + '/songs/' + IntToStr(FDownloadID) + '/download';
    end
    else
    begin
      Method := 'GET';
      URL := URL + '/songs?q=' + EncodeQuery(FQuery) + '&offset=' + IntToStr(FOffset);
    end;
    Client.HTTPMethod(Method, URL, Response, [200, 400, 401, 404, 409, 500, 503]);
    Body := UTF8String(Response.DataString);
  except
    on E: Exception do
      ErrorText := E.Message;
  end;
  Response.Free;
  Client.Free;
end;

function DecodeUSDBResults(const Body: UTF8String; out Entries: TUSDBEntries; out Total: integer; out ErrorText: UTF8String): boolean;
var
  Data: TJSONData;
  Root, Song: TJSONObject;
  Items: TJSONArray;
  I: integer;
begin
  Result := false;
  ErrorText := '';
  Total := 0;
  SetLength(Entries, 0);
  Data := nil;
  try
    Data := GetJSON(Body);
    if not (Data is TJSONObject) then
      raise Exception.Create('Invalid catalog response');
    Root := TJSONObject(Data);
    if Root.Find('error') <> nil then
      raise Exception.Create(Root.Get('error', 'Catalog request failed'));
    Total := Root.Get('total', 0);
    Items := Root.Arrays['songs'];
    SetLength(Entries, Items.Count);
    for I := 0 to Items.Count - 1 do
    begin
      Song := Items.Objects[I];
      Entries[I].ID := Song.Get('id', 0);
      Entries[I].Artist := Song.Get('artist', '');
      Entries[I].Title := Song.Get('title', '');
      Entries[I].Year := Song.Get('year', 0);
      Entries[I].Status := Song.Get('status', '');
      Entries[I].Ready := Song.Get('ready', false);
      Entries[I].Chart := Song.Get('chart', '');
    end;
    Result := true;
  except
    on E: Exception do
      ErrorText := E.Message;
  end;
  Data.Free;
end;

end.
