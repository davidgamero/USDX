program test_usdb_client;

{$MODE Delphi}
{$CODEPAGE UTF8}

uses
  {$IFDEF UNIX}cthreads, cwstring,{$ENDIF}
  SysUtils, SDL2, SDL2_image, SQLite3, SQLiteTable3, dglOpenGL,
  UUSDBClient, fpjson, jsonparser;

var
  Entries: TUSDBEntries;
  Total: integer;
  ErrorText: UTF8String;
  Request: TUSDBRequest;

procedure Check(Condition: boolean; const MessageText: string);
begin
  if not Condition then raise Exception.Create(MessageText);
end;

begin
  Check(DecodeUSDBResults('{"total":1,"songs":[{"id":22898,"artist":"Bublé","title":"Can’t Help Falling In Love","ready":true,"chart":"/songs/test.txt"}]}', Entries, Total, ErrorText), ErrorText);
  Check((Total = 1) and (Length(Entries) = 1), 'Catalog counts were not decoded');
  Check((Entries[0].Artist = 'Bublé') and Entries[0].Ready, 'Unicode or ready state was lost');
  Check(not DecodeUSDBResults('{"error":"Sign in first"}', Entries, Total, ErrorText), 'API error should be displayed');
  Check(ErrorText = 'Sign in first', 'API error text was lost');
  Check(not DecodeUSDBResults('invalid', Entries, Total, ErrorText), 'Invalid response should fail safely');
  Check(DecodeUSDBResults('{"total":0,"songs":[]}', Entries, Total, ErrorText), 'Empty results should be supported');

  if GetEnvironmentVariable('USDX_USDB_BRIDGE') <> '' then
  begin
    Request := TUSDBRequest.Create('Bublé & Elvis', 6);
    try
      Request.WaitFor;
      Check(Request.ErrorText = '', Request.ErrorText);
      Check(DecodeUSDBResults(Request.Body, Entries, Total, ErrorText), ErrorText);
      Check((Total = 20) and (Entries[0].Artist = 'Bublé'), 'Native HTTP search returned unexpected data');
    finally
      Request.Free;
    end;
    Request := TUSDBRequest.Create('', 0, 22898);
    try
      Request.WaitFor;
      Check(Request.ErrorText = '', Request.ErrorText);
      Check(Pos('Pending', Request.Body) > 0, 'Native download request was not acknowledged');
    finally
      Request.Free;
    end;
    WriteLn('PASS: native threaded HTTP search and download request');
  end;
  WriteLn('PASS: USDB result counts, Unicode, readiness, errors and empty results');
end.
