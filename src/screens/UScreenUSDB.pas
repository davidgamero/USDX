unit UScreenUSDB;

{$MODE Delphi}

interface

uses UMenu, UUSDBClient, SDL2, UUnicodeUtils;

type
  TScreenUSDB = class(TMenu)
  private
    FRequest: TUSDBRequest;
    FEntries: TUSDBEntries;
    FOffset, FTotal, FRevision: integer;
    FDownloads: array of integer;
    FNotice: UTF8String;
    FNoticeTime: cardinal;
    FLastEdit, FLastRefresh: cardinal;
    FNeedsSearch: boolean;
    FStatusText: integer;
    FFromMain: boolean;
    procedure ChangedQuery;
    procedure QueueDownload(ID: integer);
    procedure UpdateRows;
    procedure CloseBrowser;
    procedure OpenLocalSong(Index: integer);
  public
    Visible: boolean;
    constructor Create; override;
    destructor Destroy; override;
    procedure ShowBrowser(FromMain: boolean = false);
    procedure UpdateRequests;
    function Draw: boolean; override;
    function ParseInput(PressedKey: cardinal; CharCode: UCS4Char; PressedDown: boolean): boolean; override;
  end;

implementation

uses SysUtils, fpjson, jsonparser, UGraphic, UThemes, URenderer, ULanguage,
  UMain, UIni, UPath, USongs, UPlaylist;

const PageSize = 6;

constructor TScreenUSDB.Create;
var
  I, B: integer;
  ThemeButton: TThemeButton;
begin
  inherited;
  AddText(100, 68, 600, 34, Theme.SongMenu.TextMenu.Font, 0, 30, 1, 1, 1, 0,
    Language.Translate('USDB_BROWSER_TITLE'), false, 0, 0.99, false);
  AddText(100, 106, 600, 22, Theme.SongMenu.TextMenu.Font, 0, 18, 0.7, 0.8, 1, 0,
    Language.Translate('USDB_BROWSER_HINT'), false, 0, 0.99, false);
  ThemeButton := Theme.SongMenu.Button1;
  ThemeButton.X := 100;
  ThemeButton.Y := 134;
  ThemeButton.W := 600;
  ThemeButton.H := 32;
  B := AddButton(ThemeButton);
  Button[B].Text[0].Text := '';
  Button[B].Text[0].Writable := true;
  Button[B].Text[0].W := 580;
  FStatusText := AddText(100, 174, 600, 22, Theme.SongMenu.TextMenu.Font, 0, 18,
    0.8, 0.85, 1, 0, '', false, 0, 0.99, false);
  for I := 0 to PageSize - 1 do
  begin
    ThemeButton.Y := 204 + I * 45;
    ThemeButton.H := 42;
    B := AddButton(ThemeButton);
    Button[B].Text[0].Size := 20;
    Button[B].Text[0].Y := 0;
    Button[B].Text[0].W := 580;
    Button[B].Text[0].H := 22;
    AddButtonText(6, 22, 0.8, 0.85, 1, Theme.SongMenu.TextMenu.Font, 0, 15, 0, '');
    Button[B].Visible := false;
  end;
  ThemeButton.Y := 506;
  ThemeButton.W := 180;
  ThemeButton.H := 32;
  for I := 0 to 2 do
  begin
    ThemeButton.X := 100 + I * 210;
    B := AddButton(ThemeButton);
    case I of
      0: Button[B].Text[0].Text := Language.Translate('USDB_BROWSER_BACK');
      1: Button[B].Text[0].Text := Language.Translate('USDB_BROWSER_PREVIOUS');
      2: Button[B].Text[0].Text := Language.Translate('USDB_BROWSER_NEXT');
    end;
  end;
  AddText(100, 549, 600, 20, Theme.SongMenu.TextMenu.Font, 0, 16, 0.7, 0.8, 1, 0,
    Language.Translate('USDB_BROWSER_FOOTER'), false, 0, 0.99, false);
  Interaction := 0;
end;

destructor TScreenUSDB.Destroy;
begin
  if Assigned(FRequest) then
  begin
    FRequest.Terminate;
    FRequest.WaitFor;
    FRequest.Free;
  end;
  inherited;
end;

procedure TScreenUSDB.ShowBrowser(FromMain: boolean);
begin
  inherited OnShow;
  Visible := true;
  FFromMain := FromMain;
  Interaction := 0;
  StartTextInput;
  Inc(FRevision);
  FNeedsSearch := true;
  FLastEdit := SDL_GetTicks - 400;
  Text[FStatusText].Text := Language.Translate('USDB_BROWSER_SEARCHING');
end;

procedure TScreenUSDB.CloseBrowser;
begin
  Visible := false;
  StopTextInput;
  Inc(FRevision);
  ScreenSong.Refresh;
end;

procedure TScreenUSDB.ChangedQuery;
begin
  Inc(FRevision);
  FOffset := 0;
  FTotal := 0;
  FNotice := '';
  FLastEdit := SDL_GetTicks;
  FNeedsSearch := true;
  Interaction := 0;
  SetLength(FEntries, 0);
  UpdateRows;
  Text[FStatusText].Text := Language.Translate('USDB_BROWSER_SEARCHING');
end;

procedure TScreenUSDB.UpdateRows;
var
  I: integer;
  Status: UTF8String;
begin
  if (Interaction > 0) and (Interaction <= PageSize) and (Interaction > Length(FEntries)) then
    Interaction := 0;
  for I := 0 to PageSize - 1 do
  begin
    Button[I + 1].Visible := I < Length(FEntries);
    if I >= Length(FEntries) then
      Continue;
    Button[I + 1].Text[0].Text := FEntries[I].Artist + ' - ' + FEntries[I].Title;
    if FEntries[I].Ready then
      Status := Language.Translate('USDB_BROWSER_READY')
    else if FEntries[I].Status = 'Pending' then
      Status := Language.Translate('USDB_BROWSER_QUEUED')
    else if FEntries[I].Status = 'Downloading' then
      Status := Language.Translate('USDB_BROWSER_DOWNLOADING')
    else if FEntries[I].Status = 'Failed' then
      Status := Language.Translate('USDB_BROWSER_RETRY')
    else
      Status := Language.Translate('USDB_BROWSER_DOWNLOAD');
    if FEntries[I].Year > 0 then
      Status := IntToStr(FEntries[I].Year) + ' | ' + Status;
    Button[I + 1].Text[1].Text := Status;
  end;
  Button[PageSize + 2].Selectable := FOffset > 0;
  Button[PageSize + 3].Selectable := FOffset + PageSize < FTotal;
end;

procedure TScreenUSDB.QueueDownload(ID: integer);
var I: integer;
begin
  if Assigned(FRequest) and (FRequest.DownloadID = ID) then Exit;
  for I := 0 to High(FDownloads) do
    if FDownloads[I] = ID then Exit;
  SetLength(FDownloads, Length(FDownloads) + 1);
  FDownloads[High(FDownloads)] := ID;
end;

procedure TScreenUSDB.UpdateRequests;
var
  Entries: TUSDBEntries;
  Total: integer;
  ErrorText: UTF8String;
  Response: TJSONData;
  I: integer;
begin
  if Assigned(FRequest) and FRequest.Finished then
  begin
    FRequest.WaitFor;
    try
      if FRequest.DownloadID > 0 then
      begin
        ErrorText := FRequest.ErrorText;
        if ErrorText = '' then
        begin
          Response := nil;
          try
            Response := GetJSON(FRequest.Body);
            if Response is TJSONObject then
              ErrorText := TJSONObject(Response).Get('error', '');
          except
            on E: Exception do ErrorText := E.Message;
          end;
          Response.Free;
        end;
        if ErrorText <> '' then
          FNotice := Language.Translate(ErrorText)
        else
          FNotice := Language.Translate('USDB_BROWSER_REQUESTED');
        FNoticeTime := SDL_GetTicks;
        Text[FStatusText].Text := FNotice;
        FNeedsSearch := true;
      end
      else if (FRequest.Revision = FRevision) and (FRequest.Offset = FOffset) then
      begin
        ErrorText := FRequest.ErrorText;
        if (ErrorText = '') and DecodeUSDBResults(FRequest.Body, Entries, Total, ErrorText) then
        begin
          FEntries := Entries;
          FTotal := Total;
          UpdateRows;
          if (FNotice <> '') and (SDL_GetTicks - FNoticeTime < 5000) then
            Text[FStatusText].Text := FNotice
          else
            Text[FStatusText].Text := Format(Language.Translate('USDB_BROWSER_RESULTS'),
              [FTotal, FOffset div PageSize + 1]);
        end
        else if FRequest.ErrorText <> '' then
          Text[FStatusText].Text := Language.Translate('USDB_BROWSER_CONNECTION_ERROR') + ' ' + Language.Translate(ErrorText)
        else
          Text[FStatusText].Text := Language.Translate(ErrorText);
      end;
    finally
      FreeAndNil(FRequest);
    end;
  end;
  if Assigned(FRequest) then
    Exit;
  if Length(FDownloads) > 0 then
  begin
    FRequest := TUSDBRequest.Create(Button[0].Text[0].Text, FOffset, FDownloads[0]);
    for I := 1 to High(FDownloads) do
      FDownloads[I - 1] := FDownloads[I];
    SetLength(FDownloads, Length(FDownloads) - 1);
  end
  else if Visible and ((FNeedsSearch and (SDL_GetTicks - FLastEdit >= 350)) or
          (not FNeedsSearch and (SDL_GetTicks - FLastRefresh >= 2000))) then
  begin
    FNeedsSearch := false;
    FLastRefresh := SDL_GetTicks;
    FRequest := TUSDBRequest.Create(Button[0].Text[0].Text, FOffset);
    FRequest.Revision := FRevision;
  end;
end;

procedure TScreenUSDB.OpenLocalSong(Index: integer);
var
  Chart: IPath;
  I, J: integer;
begin
  Chart := Path(FEntries[Index].Chart);
  CloseBrowser;
  PlaylistMan.UnsetPlaylist;
  CatSongs.SetFilter('', fltAll);
  for I := 0 to High(CatSongs.Song) do
    if not CatSongs.Song[I].Main and CatSongs.Song[I].Path.Append(CatSongs.Song[I].FileName).Equals(Chart) then
    begin
      if Ini.Tabs = 1 then
      begin
        CatSongs.ShowCategory(CatSongs.Song[I].OrderNum);
        for J := 0 to High(CatSongs.Song) do
          if CatSongs.Song[J].Main and (CatSongs.Song[J].OrderNum = CatSongs.Song[I].OrderNum) then
          begin
            ScreenSong.ShowCatTL(J);
            Break;
          end;
      end;
      ScreenSong.SkipTo(CatSongs.VisibleIndex(I), I, CatSongs.VisibleSongs);
      ScreenSong.SetScrollRefresh;
      if FFromMain then
        ScreenMain.FadeTo(@ScreenSong);
      Exit;
    end;
end;

function TScreenUSDB.ParseInput(PressedKey: cardinal; CharCode: UCS4Char; PressedDown: boolean): boolean;
begin
  Result := true;
  if not PressedDown then Exit;
  if (PressedKey = SDLK_A) and ((SDL_GetModState and (KMOD_CTRL or KMOD_GUI)) <> 0) then
  begin
    Button[0].Text[0].Text := '';
    ChangedQuery;
    Exit;
  end;
  if IsAlphaNumericChar(CharCode) or IsPunctuationChar(CharCode) or (CharCode = Ord(' ')) then
  begin
    if Length(Button[0].Text[0].Text) < 200 then
      Button[0].Text[0].Text := Button[0].Text[0].Text + UCS4ToUTF8String(CharCode);
    ChangedQuery;
    Exit;
  end;
  case PressedKey of
    SDLK_ESCAPE: CloseBrowser;
    SDLK_BACKSPACE:
      begin
        Button[0].Text[0].DeleteLastLetter;
        ChangedQuery;
      end;
    SDLK_DOWN, SDLK_TAB: InteractNext;
    SDLK_UP: InteractPrev;
    SDLK_RETURN:
      if Interaction = 0 then
      begin
        FNeedsSearch := true;
        FLastEdit := SDL_GetTicks - 400;
      end
      else if (Interaction > 0) and (Interaction <= Length(FEntries)) then
      begin
        if FEntries[Interaction - 1].Ready then
          OpenLocalSong(Interaction - 1)
        else if not (FEntries[Interaction - 1].Status = 'Pending') and
                    not (FEntries[Interaction - 1].Status = 'Downloading') then
        begin
          QueueDownload(FEntries[Interaction - 1].ID);
          Text[FStatusText].Text := Language.Translate('USDB_BROWSER_QUEUEING');
        end;
      end
      else if Interaction = PageSize + 1 then
        CloseBrowser
      else if ((Interaction = PageSize + 2) and (FOffset > 0)) or
              ((Interaction = PageSize + 3) and (FOffset + PageSize < FTotal)) then
      begin
        if Interaction = PageSize + 2 then Dec(FOffset, PageSize) else Inc(FOffset, PageSize);
        Inc(FRevision);
        FNeedsSearch := true;
        FLastEdit := SDL_GetTicks - 400;
      end;
  end;
end;

function TScreenUSDB.Draw: boolean;
begin
  Renderer.ClearFrameBuffer(CLEAR_DEPTH);
  Renderer.DrawQuad(0, 0, 0.95, 800, 600, 0, 0, 0, 0.8);
  Renderer.DrawQuad(80, 50, 0.96, 640, 530, 0.04, 0.06, 0.12, 1);
  Result := DrawFG;
end;

end.
