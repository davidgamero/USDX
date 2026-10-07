{* UltraStar Deluxe - Karaoke Game
 *
 * UltraStar Deluxe is the legal property of its developers, whose names
 * are too numerous to list here. Please refer to the COPYRIGHT
 * file distributed with this source distribution.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; see the file COPYING. If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 *
 * $URL: https://ultrastardx.svn.sourceforge.net/svnroot/ultrastardx/trunk/src/screens/UScreenSongMenu.pas $
 * $Id: UScreenSongMenu.pas 2071 2010-01-12 17:42:41Z s_alexander $
 *}

unit UScreenSongMenu;

interface

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

uses
  UDisplay,
  UInstrumental,
  UFiles,
  UIni,
  UMenu,
  UMusic,
  UThemes,
  sdl2,
  SysUtils;

type
  TScreenSongMenu = class(TMenu)
    private
      CurMenu: byte; // num of the cur. shown menu
      ID:       String; //for help-system
      LastInstrumentalUpdate: cardinal;
      InstrumentalProgress: TInstrumentalProgress;
      InstrumentalTexts: array[0..3] of integer;
      procedure UpdateInstrumentalButton;
      procedure HandleInstrumental;
      procedure DrawInstrumentalProgress;
    public
      Visible: boolean; // whether the menu should be drawn

      constructor Create; override;
      function ParseInput(PressedKey: cardinal; CharCode: UCS4Char; PressedDown: boolean): boolean; override;
      procedure OnShow; override;
      function Draw: boolean; override;
      procedure MenuShow(sMenu: byte);
      procedure HandleReturn;
      function CountMedleySongs: integer;
      procedure UpdateJukeboxButtons;
  end;

const
  SM_Main = 1;

  SM_PlayList         = 64 or 1;
  SM_Playlist_Add     = 64 or 2;
  SM_Playlist_New     = 64 or 3;

  SM_Playlist_DelItem = 64 or 5;

  SM_Playlist_Load    = 64 or 8 or 1;
  SM_Playlist_Del     = 64 or 8 or 5;

  SM_Party_Main       = 128 or 1;
  SM_Party_Joker      = 128 or 2;
  SM_Party_Free_Main  = 128 or 5;

  SM_Refresh_Scores   = 64 or 6;
  SM_Song             = 64 or 8;
  SM_Medley           = 64 or 16;
  SM_Jukebox          = 64 or 128;

var
  ISelections1: array of UTF8String;
  SelectValue1: integer;

  ISelections2: array of UTF8String;
  SelectValue2: integer;

  ISelections3: array of UTF8String;
  SelectValue3: integer;

implementation

uses
  UDatabase,
  Math,
  UGraphic,
  UHelp,
  ULanguage,
  ULog,
  UMain,
  UNote,
  UParty,
  UPlaylist,
  URenderer,
  USong,
  USongs,
  UUnicodeUtils;

function TScreenSongMenu.ParseInput(PressedKey: cardinal; CharCode: UCS4Char; PressedDown: boolean): boolean;
var
  SDL_ModState:  Word;

begin
  Result := true;
  if (PressedDown) then
  begin // key down
    if (CurMenu = SM_Playlist_New) and (Interaction=1) then
    begin
      // check normal keys
      if IsAlphaNumericChar(CharCode) or
         (CharCode in [Ord(' '), Ord('-'), Ord('_'), Ord('!'),
                       Ord(','), Ord('<'), Ord('/'), Ord('*'),
                       Ord('?'), Ord(''''), Ord('"')]) then
      begin
        Button[Interaction].Text[0].Text := Button[Interaction].Text[0].Text +
                                            UCS4ToUTF8String(CharCode);
        exit;
      end;

      // check special keys
      case PressedKey of
        SDLK_BACKSPACE:
          begin
            Button[Interaction].Text[0].DeleteLastLetter;
            exit;
          end;
      end;
    end;

    // check normal keys unless a text field is actively selected
    if not ((CurMenu = SM_Playlist_New) and Button[1].Selected) then
    begin
      case PressedKey of
        SDLK_Q:
          begin
            Result := false;
            Exit;
          end;
      end;
    end;

    SDL_ModState := SDL_GetModState and (KMOD_LSHIFT + KMOD_RSHIFT
    + KMOD_LCTRL + KMOD_RCTRL + KMOD_LALT  + KMOD_RALT);

    // check special keys
    case PressedKey of
      SDLK_ESCAPE,
      SDLK_BACKSPACE:
        begin
          StopTextInput;
          AudioPlayback.PlaySound(SoundLib.Back);
          Visible := false;
        end;

      SDLK_TAB:
        begin
          Help.SetHelpID(ID);
          ScreenPopupHelp.ShowPopup();
        end;

      SDLK_RETURN:
        begin
          StopTextInput;
          HandleReturn;
        end;

      SDLK_DOWN:
        begin
          InteractNext;
          SetTextInput((CurMenu = SM_Playlist_New) and (Button[1].Selected));
        end;

      SDLK_UP:
        begin
          InteractPrev;
          SetTextInput((CurMenu = SM_Playlist_New) and (Button[1].Selected));
        end;

      SDLK_RIGHT:
        begin
          if (ScreenSong.Mode <> smJukebox) then
          begin
            if (Interaction=3) or (Interaction=4) or (Interaction=5)
              or (Interaction=8) or (Interaction=9) or (Interaction=10) then
                InteractInc;
          end
          else
          begin
            ScreenSong.PlayNavigationSound;
            ScreenSong.SelectNext;
            ScreenSong.SetScrollRefresh;
          end;
        end;
      SDLK_LEFT:
        begin
          if (ScreenSong.Mode <> smJukebox) then
          begin
            if (Interaction=3) or (Interaction=4) or (Interaction=5)
              or (Interaction=8) or (Interaction=9) or (Interaction=10) then
                InteractDec;
          end
          else
          begin
            ScreenSong.PlayNavigationSound;
            ScreenSong.SelectPrev;
            ScreenSong.SetScrollRefresh;
          end;
        end;

      SDLK_1:
        begin // joker
            // use joker
          case CurMenu of
            SM_Party_Main:
            begin
              ScreenSong.DoJoker(0, SDL_ModState)
            end;
          end;
        end;
      SDLK_2:
        begin // joker
            // use joker
          case CurMenu of
            SM_Party_Main:
            begin
              ScreenSong.DoJoker(1, SDL_ModState)
            end;
          end;
        end;
      SDLK_3:
        begin // joker
            // use joker
          case CurMenu of
            SM_Party_Main:
            begin
              ScreenSong.DoJoker(2, SDL_ModState)
            end;
          end;
        end;
    end; // case
  end; // if
end;

constructor TScreenSongMenu.Create;
var
  I: integer;
begin
  inherited Create;

  // create dummy selectslide entrys
  SetLength(ISelections1, 1);
  ISelections1[0] := 'Dummy';

  SetLength(ISelections2, 1);
  ISelections2[0] := 'Dummy';

  SetLength(ISelections3, 1);
  ISelections3[0] := 'Dummy';

  AddText(Theme.SongMenu.TextMenu);

  LoadFromTheme(Theme.SongMenu);

  AddButton(Theme.SongMenu.Button1);
  if (Length(Button[0].Text) = 0) then
    AddButtonText(14, 20, 'Button 1');

  AddButton(Theme.SongMenu.Button2);
  if (Length(Button[1].Text) = 0) then
    AddButtonText(14, 20, 'Button 2');

  AddButton(Theme.SongMenu.Button3);
  if (Length(Button[2].Text) = 0) then
    AddButtonText(14, 20, 'Button 3');

  AddSelectSlide(Theme.SongMenu.SelectSlide1, SelectValue1, ISelections1);
  AddSelectSlide(Theme.SongMenu.SelectSlide2, SelectValue2, ISelections2);
  AddSelectSlide(Theme.SongMenu.SelectSlide3, SelectValue3, ISelections3);

  AddButton(Theme.SongMenu.Button4);
  if (Length(Button[3].Text) = 0) then
    AddButtonText(14, 20, 'Button 4');

  AddButton(Theme.SongMenu.Button5);
  if (Length(Button[4].Text) = 0) then
    AddButtonText(14, 20, 'Button 5');

  for I := 0 to High(InstrumentalTexts) do
  begin
    InstrumentalTexts[I] := AddText(0, 0, 240, 22,
      Theme.SongMenu.TextMenu.Font, Theme.SongMenu.TextMenu.Style,
      18, 1, 1, 1, 0, '', false, 0, 0.99, false);
    Text[InstrumentalTexts[I]].Visible := false;
  end;

  Interaction := 0;
end;

function TScreenSongMenu.Draw: boolean;
begin
  if (SDL_GetTicks - LastInstrumentalUpdate >= 1000) then
    UpdateInstrumentalButton;
  Renderer.ClearFrameBuffer(CLEAR_DEPTH);
  Result := inherited Draw;
  DrawInstrumentalProgress;
end;

procedure TScreenSongMenu.DrawInstrumentalProgress;
var
  X, Y, W, FillWidth: single;
  I: integer;
  Lines: array[0..3] of UTF8String;

  function TimeText(Seconds: integer; Estimate: boolean = false): UTF8String;
  begin
    if Seconds < 0 then
      Result := Language.Translate('INSTRUMENTAL_ESTIMATING')
    else
    begin
      if Estimate then
        Seconds := ((Seconds + 4) div 5) * 5;
      Result := Format('%d:%.2d', [Seconds div 60, Seconds mod 60]);
      if Estimate then
        Result := '~' + Result;
    end;
  end;

begin
  if not (CurMenu in [SM_Main, SM_PlayList]) or
     (InstrumentalProgress.State = isMissing) then
    Exit;
  W := Max(260, Theme.SongMenu.Button1.W + 20);
  X := Max(10, Min(Theme.SongMenu.Button1.X - 10, 790 - W));
  Y := Min(Theme.SongMenu.Button5.Y + Theme.SongMenu.Button5.H + 12, 450);
  for I := 0 to 3 do
    Lines[I] := '';
  if InstrumentalProgress.State = isStalled then
  begin
    Lines[0] := Language.Translate('INSTRUMENTAL_WORKER_STALLED');
    Lines[1] := Language.Translate('INSTRUMENTAL_PROGRESS_PAUSED');
  end
  else if InstrumentalProgress.State = isFailed then
  begin
    Lines[0] := Language.Translate('INSTRUMENTAL_FAILED');
    Lines[1] := InstrumentalProgress.ErrorText;
    Lines[2] := Language.Translate('INSTRUMENTAL_RETRY');
  end
  else if InstrumentalProgress.State = isReady then
  begin
    Lines[0] := Language.Translate('INSTRUMENTAL_READY');
    if InstrumentalProgress.ElapsedSeconds >= 0 then
      Lines[1] := Format(Language.Translate('INSTRUMENTAL_COMPLETED_TIME'), [TimeText(InstrumentalProgress.ElapsedSeconds)]);
    Lines[2] := Language.Translate('INSTRUMENTAL_READY_HINT');
  end
  else if InstrumentalProgress.State = isQueued then
  begin
    Lines[0] := Language.Translate('INSTRUMENTAL_QUEUED');
    Lines[1] := Format(Language.Translate('INSTRUMENTAL_CONVERSION_TIME'), [TimeText(InstrumentalProgress.ProcessingSeconds, true)]);
    if InstrumentalProgress.QueuePosition > 0 then
      Lines[2] := Format(Language.Translate('INSTRUMENTAL_QUEUE_WAIT'), [InstrumentalProgress.QueuePosition, TimeText(InstrumentalProgress.WaitSeconds, true)])
    else
      Lines[2] := Language.Translate('INSTRUMENTAL_QUEUE_STARTING');
  end
  else
  begin
    Lines[0] := Language.Translate('INSTRUMENTAL_STAGE_' + UpperCase(InstrumentalProgress.Stage));
    if InstrumentalProgress.Stage = 'processing' then
      Lines[0] := Language.Translate('INSTRUMENTAL_PROCESSING');
    if InstrumentalProgress.Percent >= 0 then
      Lines[0] := Lines[0] + Format(' - %d%%', [InstrumentalProgress.Percent]);
    if InstrumentalProgress.RemainingSeconds >= 0 then
      Lines[1] := Format(Language.Translate('INSTRUMENTAL_ELAPSED_REMAINING'),
        [TimeText(InstrumentalProgress.ElapsedSeconds), TimeText(InstrumentalProgress.RemainingSeconds, true)])
    else
      Lines[1] := Format(Language.Translate('INSTRUMENTAL_ELAPSED_ESTIMATING'), [TimeText(InstrumentalProgress.ElapsedSeconds)]);
    if InstrumentalProgress.ChunksTotal > 0 then
      Lines[2] := Format(Language.Translate('INSTRUMENTAL_CHUNKS'),
        [InstrumentalProgress.ChunksDone, InstrumentalProgress.ChunksTotal]);
  end;
  if InstrumentalProgress.State in [isQueued, isProcessing] then
  begin
    Lines[3] := Format(Language.Translate('INSTRUMENTAL_WAITING_COUNT'), [InstrumentalProgress.JobsWaiting]);
    if InstrumentalProgress.Confidence = 'learning' then
      Lines[3] := Lines[3] + ' | ' + Language.Translate('INSTRUMENTAL_LEARNING');
  end;

  Renderer.ClearFrameBuffer(CLEAR_DEPTH);
  Renderer.DrawQuad(X, Y, 0.98, W, 130, 0.04, 0.06, 0.12, 0.95);
  Renderer.DrawQuad(X + 10, Y + 38, 0.99, W - 20, 6, 0.2, 0.25, 0.3, 1);
  if not (InstrumentalProgress.State in [isStalled, isFailed]) then
  begin
    if InstrumentalProgress.Percent >= 0 then
    begin
      FillWidth := (W - 20) * EnsureRange(InstrumentalProgress.Percent, 0, 100) / 100;
      Renderer.DrawQuad(X + 10, Y + 38, 0.99, FillWidth, 6, 0.25, 0.75, 1, 1);
    end
    else
      Renderer.DrawQuad(X + 10 + (W - 60) * (SDL_GetTicks mod 2000) / 2000,
        Y + 38, 0.99, 40, 6, 0.25, 0.75, 1, 1);
  end;
  for I := 0 to 3 do
  begin
    Text[InstrumentalTexts[I]].X := X + 10;
    Text[InstrumentalTexts[I]].Y := Y + 8 + I * 25;
    if I > 0 then
      Text[InstrumentalTexts[I]].Y := Text[InstrumentalTexts[I]].Y + 16;
    Text[InstrumentalTexts[I]].W := W - 20;
    Text[InstrumentalTexts[I]].Size := 18;
    Text[InstrumentalTexts[I]].Text := Lines[I];
    Text[InstrumentalTexts[I]].Visible := true;
    Text[InstrumentalTexts[I]].Draw;
    Text[InstrumentalTexts[I]].Visible := false;
  end;
end;

procedure TScreenSongMenu.UpdateInstrumentalButton;
var
  ButtonIndex: integer;
  Caption: UTF8String;
  State: TInstrumentalState;
begin
  LastInstrumentalUpdate := SDL_GetTicks;
  InstrumentalProgress.State := isMissing;
  if CurMenu = SM_Main then
    ButtonIndex := 2
  else if CurMenu = SM_PlayList then
    ButtonIndex := 4
  else
    Exit;
  if (ScreenSong.Interaction < 0) or (ScreenSong.Interaction > High(CatSongs.Song)) then
    Exit;
  Button[ButtonIndex].Visible := not CatSongs.Song[ScreenSong.Interaction].Main;
  InstrumentalProgress := ReadInstrumentalProgress(CatSongs.Song[ScreenSong.Interaction]);
  State := InstrumentalProgress.State;
  case State of
    isQueued: Caption := 'INSTRUMENTAL_QUEUED';
    isProcessing:
      if InstrumentalProgress.Stage = 'processing' then
        Caption := 'INSTRUMENTAL_PROCESSING'
      else
        Caption := 'INSTRUMENTAL_STAGE_' + UpperCase(InstrumentalProgress.Stage);
    isFailed: Caption := 'INSTRUMENTAL_RETRY';
    isStalled: Caption := 'INSTRUMENTAL_WORKER_STALLED';
    isReady:
      if Ini.VocalsVolume = 0 then
        Caption := 'INSTRUMENTAL_USE_ORIGINAL'
      else
        Caption := 'INSTRUMENTAL_USE';
    else Caption := 'INSTRUMENTAL_MAKE';
  end;
  Button[ButtonIndex].Text[0].Text := Language.Translate(Caption);
end;

procedure TScreenSongMenu.HandleInstrumental;
var
  Song: TSong;
  ErrorText: UTF8String;
  State: TInstrumentalState;
begin
  if (ScreenSong.Interaction < 0) or (ScreenSong.Interaction > High(CatSongs.Song)) then
    Exit;
  Song := CatSongs.Song[ScreenSong.Interaction];
  State := InstrumentalState(Song, ErrorText);
  if State = isReady then
  begin
    if Ini.VocalsVolume = 0 then
      Ini.VocalsVolume := 100
    else
      Ini.VocalsVolume := 0;
    Ini.Save;
    ScreenSong.StopMusicPreview;
    ScreenSong.StopVideoPreview;
    ScreenSong.SongIndex := -1;
    ScreenSong.ChangeMusic;
  end
  else if not (State in [isQueued, isProcessing]) then
  begin
    if not QueueInstrumental(Song, ErrorText) then
      ScreenPopupError.ShowPopup(Language.Translate(ErrorText));
  end;
  UpdateInstrumentalButton;
end;

procedure TScreenSongMenu.OnShow;
begin
  inherited;
end;

function TScreenSongMenu.CountMedleySongs: integer;
var
  Count, I: integer;
begin

  Count := 0;

  for I:= 0 to High(CatSongs.Song) do
  begin

    if (CatSongs.Song[I].Visible) and (CatSongs.Song[I].Medley.Source <> msNone) then
      Count := Count + 1;

    if (Count = 5) then
      break;

  end;

  Result := Count;
end;

procedure TScreenSongMenu.UpdateJukeboxButtons();
begin
   Button[1].Visible := not (CatSongs.Song[ScreenSong.Interaction].Main);
   Button[2].Visible := (Length(ScreenJukebox.JukeboxSongsList) > 0);

   if (CatSongs.Song[ScreenSong.Interaction].Main) then
     Button[0].Text[0].Text := Language.Translate('SONG_MENU_OPEN_CATEGORY')
   else
     Button[0].Text[0].Text := Language.Translate('SONG_MENU_CLOSE_CATEGORY');
end;

procedure TScreenSongMenu.MenuShow(sMenu: byte);
var
  I, MSongs: integer;
begin
  Interaction := 0; // reset interaction
  Visible := true;  // set visible
  case sMenu of
    SM_Main:
      begin
        ID := 'ID_017';
        CurMenu := sMenu;

        Text[0].Text := Language.Translate('SONG_MENU_NAME_MAIN');

        Button[0].Visible := true;
        Button[1].Visible := ((Length(PlaylistMedley.Song) > 0) or (CatSongs.Song[ScreenSong.Interaction].Medley.Source > msNone));
        Button[2].Visible := false;
        Button[3].Visible := true;
        Button[4].Visible := false;

        SelectsS[0].Visible := false;
        SelectsS[1].Visible := false;
        SelectsS[2].Visible := false;

        Button[0].Text[0].Text := Language.Translate('SONG_MENU_SONG');
        Button[1].Text[0].Text := Language.Translate('SONG_MENU_MEDLEY');
        Button[3].Text[0].Text := Language.Translate('SONG_MENU_REFRESH_SCORES');
        Button[4].Visible := ScreenSong.FreeListMode and not ScreenSong.MakeMedley;
        Button[4].Text[0].Text := Language.Translate('USDB_BROWSER_TITLE');
      end;
    SM_Song:
      begin
        ID := 'ID_017';
        CurMenu := sMenu;
        Text[0].Text := Language.Translate('SONG_MENU_NAME_SONG');

        Button[0].Visible := true;
        Button[1].Visible := true;
        Button[2].Visible := true;
        Button[3].Visible := true;
        Button[4].Visible := true;

        SelectsS[0].Visible := false;
        SelectsS[1].Visible := false;
        SelectsS[2].Visible := false;

        Button[0].Text[0].Text := Language.Translate('SONG_MENU_PLAY');
        Button[1].Text[0].Text := Language.Translate('SONG_MENU_CHANGEPLAYERS');
        Button[2].Text[0].Text := Language.Translate('SONG_MENU_PLAYLIST_ADD');
        Button[3].Text[0].Text := Language.Translate('SONG_MENU_EDIT');
        Button[4].Text[0].Text := Language.Translate('SONG_MENU_CANCEL');
      end;

    SM_Medley:
      begin
        ID := 'ID_017';
        CurMenu := sMenu;
        MSongs := CountMedleySongs;

        Text[0].Text := Language.Translate('SONG_MENU_NAME_MEDLEY');

        Button[0].Visible := (CatSongs.Song[ScreenSong.Interaction].Medley.Source > msNone);
        Button[1].Visible := (Length(PlaylistMedley.Song)>0);
        Button[2].Visible := (Length(PlaylistMedley.Song)>0) or
          (CatSongs.Song[ScreenSong.Interaction].Medley.Source > msNone);
        Button[3].Visible := (not ScreenSong.MakeMedley) and (MSongs > 1);
        Button[4].Visible := true;

        SelectsS[0].Visible := false;
        SelectsS[1].Visible := false;
        SelectsS[2].Visible := false;

        Button[0].Text[0].Text := Language.Translate('SONG_MENU_ADD_SONG');
        Button[1].Text[0].Text := Language.Translate('SONG_MENU_DELETE_SONG');
        Button[2].Text[0].Text := Language.Translate('SONG_MENU_START_MEDLEY');
        Button[3].Text[0].Text := Format(Language.Translate('SONG_MENU_START_5_MEDLEY'), [MSongs]);
        Button[4].Text[0].Text := Language.Translate('SONG_MENU_CANCEL');
      end;

    SM_PlayList:
      begin
        ID := 'ID_017';
        CurMenu := sMenu;
        Text[0].Text := Language.Translate('SONG_MENU_NAME_PLAYLIST');

        Button[0].Visible := true;
        Button[1].Visible := true;
        Button[2].Visible := true;
        Button[3].Visible := true;
        Button[4].Visible := false;

        SelectsS[0].Visible := false;
        SelectsS[1].Visible := false;
        SelectsS[2].Visible := false;

        Button[0].Text[0].Text := Language.Translate('SONG_MENU_PLAY');
        Button[1].Text[0].Text := Language.Translate('SONG_MENU_CHANGEPLAYERS');
        Button[2].Text[0].Text := Language.Translate('SONG_MENU_PLAYLIST_DEL');
        Button[3].Text[0].Text := Language.Translate('SONG_MENU_EDIT');
      end;

    SM_Playlist_Add:
      begin
        ID := 'ID_017';
        CurMenu := sMenu;
        Text[0].Text := Language.Translate('SONG_MENU_NAME_PLAYLIST_ADD');

        Button[0].Visible := true;
        Button[1].Visible := false;
        Button[2].Visible := false;
        Button[3].Visible := true;
        Button[4].Visible := true;

        SelectsS[0].Visible := false;
        SelectsS[1].Visible := false;
        SelectsS[2].Visible := true;

        Button[0].Text[0].Text := Language.Translate('SONG_MENU_PLAYLIST_ADD_NEW');
        Button[3].Text[0].Text := Language.Translate('SONG_MENU_PLAYLIST_ADD_EXISTING');
        Button[4].Text[0].Text := Language.Translate('SONG_MENU_CANCEL');

        SetLength(ISelections3, Length(PlaylistMan.Playlists));
        PlaylistMan.GetNames(ISelections3);

        if (Length(ISelections3)>=1) then
        begin
          UpdateSelectSlideOptions(2, ISelections3, SelectValue3);
        end
        else
        begin
          Button[3].Visible := false;
          SelectsS[0].Visible := false;
          SelectsS[1].Visible := false;
          SelectsS[2].Visible := false;
          Button[2].Visible := true;
          Button[2].Text[0].Text := Language.Translate('SONG_MENU_PLAYLIST_NOEXISTING');
        end;
      end;

    SM_Playlist_New:
      begin
        ID := 'ID_017';
        CurMenu := sMenu;
        Text[0].Text := Language.Translate('SONG_MENU_NAME_PLAYLIST_NEW');

        Button[0].Visible := false;
        Button[1].Visible := true;
        Button[2].Visible := false;
        Button[3].Visible := true;
        Button[4].Visible := true;

        SelectsS[0].Visible := false;
        SelectsS[1].Visible := false;
        SelectsS[2].Visible := false;

        Button[1].Text[0].Text := Language.Translate('SONG_MENU_PLAYLIST_NEW_UNNAMED');
        Button[3].Text[0].Text := Language.Translate('SONG_MENU_PLAYLIST_NEW_CREATE');
        Button[4].Text[0].Text := Language.Translate('SONG_MENU_CANCEL');

        Interaction := 1;
        // button 1 = a text field and pre-selected
        // it's necessary to start text input manually because it doesn't get here by Up/Down keypresses
        StartTextInput;
      end;

    SM_Playlist_DelItem:
      begin
        ID := 'ID_017';
        CurMenu := sMenu;
        Text[0].Text := Language.Translate('SONG_MENU_NAME_PLAYLIST_DELITEM');

        Button[0].Visible := true;
        Button[1].Visible := false;
        Button[2].Visible := false;
        Button[3].Visible := true;
        Button[4].Visible := false;

        SelectsS[0].Visible := false;
        SelectsS[1].Visible := false;
        SelectsS[2].Visible := false;

        Button[0].Text[0].Text := Language.Translate('SONG_MENU_YES');
        Button[3].Text[0].Text := Language.Translate('SONG_MENU_CANCEL');
      end;

    SM_Playlist_Load:
      begin
        ID := 'ID_017';
        CurMenu := sMenu;
        Text[0].Text := Language.Translate('SONG_MENU_NAME_PLAYLIST_LOAD');

        // show delete curent playlist button when playlist is opened
        Button[0].Visible := (CatSongs.CatNumShow = -3);

        Button[1].Visible := false;
        Button[2].Visible := false;
        Button[3].Visible := true;
        Button[4].Visible := false;

        SelectsS[0].Visible := false;
        SelectsS[1].Visible := false;
        SelectsS[2].Visible := true;

        Button[0].Text[0].Text := Language.Translate('SONG_MENU_PLAYLIST_DELCURRENT');
        Button[3].Text[0].Text := Language.Translate('SONG_MENU_PLAYLIST_LOAD');

        SetLength(ISelections3, Length(PlaylistMan.Playlists));
        PlaylistMan.GetNames(ISelections3);

        if (Length(ISelections3)>=1) then
        begin
          UpdateSelectSlideOptions(2, ISelections3, SelectValue3);
          Interaction := 3;
        end
        else
        begin
          Button[3].Visible := false;
          SelectsS[0].Visible := false;
          SelectsS[1].Visible := false;
          SelectsS[2].Visible := false;
          Button[2].Visible := true;
          Button[2].Text[0].Text := Language.Translate('SONG_MENU_PLAYLIST_NOEXISTING');
          Interaction := 2;
        end;
      end;

    SM_Playlist_Del:
      begin
        ID := 'ID_017';
        CurMenu := sMenu;
        Text[0].Text := Language.Translate('SONG_MENU_NAME_PLAYLIST_DEL');

        Button[0].Visible := true;
        Button[1].Visible := false;
        Button[2].Visible := false;
        Button[3].Visible := true;
        Button[4].Visible := false;

        SelectsS[0].Visible := false;
        SelectsS[1].Visible := false;
        SelectsS[2].Visible := false;

        Button[0].Text[0].Text := Language.Translate('SONG_MENU_YES');
        Button[3].Text[0].Text := Language.Translate('SONG_MENU_CANCEL');
      end;

    SM_Party_Main:
      begin
        ID := 'ID_018';
        CurMenu := sMenu;
        Text[0].Text := Language.Translate('SONG_MENU_NAME_PARTY_MAIN');

        Button[0].Visible := true;
        Button[1].Visible := false;
        Button[2].Visible := false;
        Button[3].Visible := true;
        Button[4].Visible := false;

        SelectsS[0].Visible := false;
        SelectsS[1].Visible := false;
        SelectsS[2].Visible := false;

        Button[0].Text[0].Text := Language.Translate('SONG_MENU_PLAY');
        //Button[1].Text[0].Text := Language.Translate('SONG_MENU_JOKER');
        //Button[2].Text[0].Text := Language.Translate('SONG_MENU_PLAYMODI');
        Button[3].Text[0].Text := Language.Translate('SONG_MENU_JOKER');
      end;

    SM_Party_Joker:
      begin
        ID := 'ID_018';
        CurMenu := sMenu;
        Text[0].Text := Language.Translate('SONG_MENU_NAME_PARTY_JOKER');
        // to-do : Party
        Button[0].Visible := (Length(Party.Teams) >= 1) AND (Party.Teams[0].JokersLeft > 0);
        Button[1].Visible := (Length(Party.Teams) >= 2) AND (Party.Teams[1].JokersLeft > 0);
        Button[2].Visible := (Length(Party.Teams) >= 3) AND (Party.Teams[2].JokersLeft > 0);
        Button[3].Visible := True;
        Button[4].Visible := false;

        SelectsS[0].Visible := False;
        SelectsS[1].Visible := False;
        SelectsS[2].Visible := False;

        if (Button[0].Visible) then
          Button[0].Text[0].Text := UTF8String(Party.Teams[0].Name);
        if (Button[1].Visible) then
          Button[1].Text[0].Text := UTF8String(Party.Teams[1].Name);
        if (Button[2].Visible) then
          Button[2].Text[0].Text := UTF8String(Party.Teams[2].Name);
        Button[3].Text[0].Text := Language.Translate('SONG_MENU_CANCEL');

        // set right interaction
        if (not Button[0].Visible) then
        begin
          if (not Button[1].Visible) then
          begin
            if (not Button[2].Visible) then
              Interaction := 4
            else
              Interaction := 2;
          end
          else
            Interaction := 1;
        end;

      end;

    SM_Refresh_Scores:
      begin
        ID := 'ID_019';
        CurMenu := sMenu;
        Text[0].Text := Language.Translate('SONG_MENU_REFRESH_SCORES_TITLE');

        Button[0].Visible := false;
        Button[1].Visible := false;
        Button[2].Visible := false;
        Button[3].Visible := false;
        Button[4].Visible := true;

        SelectsS[0].Visible := true;
        SelectsS[1].Visible := true;
        SelectsS[2].Visible := true;

        Button[4].Text[0].Text := Language.Translate('SONG_MENU_REFRESH_SCORES_REFRESH');

        if (High(DataBase.NetworkUser) > 0) then
          SetLength(ISelections3, Length(DataBase.NetworkUser) + 1)
        else
          SetLength(ISelections3, Length(DataBase.NetworkUser));

        if (Length(ISelections3) >= 1) then
        begin
          if (High(DataBase.NetworkUser) > 0) then
          begin
            ISelections3[0] := Language.Translate('SONG_MENU_REFRESH_SCORES_ALL_WEB');
            for I := 0 to High(DataBase.NetworkUser) do
              ISelections3[I + 1] := DataBase.NetworkUser[I].Website;
          end
          else
          begin
            for I := 0 to High(DataBase.NetworkUser) do
              ISelections3[I] := DataBase.NetworkUser[I].Website;
          end;

          UpdateSelectSlideOptions(0, [Language.Translate('SONG_MENU_REFRESH_SCORES_ONLINE'), Language.Translate('SONG_MENU_REFRESH_SCORES_FILE')], SelectValue1);
          UpdateSelectSlideOptions(1, [Language.Translate('SONG_MENU_REFRESH_SCORES_ONLY_SONG'), Language.Translate('SONG_MENU_REFRESH_SCORES_ALL_SONGS')], SelectValue2);
          UpdateSelectSlideOptions(2, ISelections3, SelectValue3);

          Interaction := 3;
        end
        else
        begin
          Button[3].Visible := false;
          SelectsS[0].Visible := false;
          SelectsS[1].Visible := false;
          SelectsS[2].Visible := false;
          Button[2].Visible := true;
          Button[2].Text[0].Text := Language.Translate('SONG_MENU_REFRESH_SCORES_NO_WEB');
          Button[2].Selectable := false;
          Button[3].Text[0].Text := Theme.Options.Description[OPTIONS_DESC_INDEX_NETWORK];
          Interaction := 7;
        end;
      end;

    SM_Party_Free_Main:
      begin
        ID := 'ID_017';
        CurMenu := sMenu;
        Text[0].Text := Language.Translate('SONG_MENU_NAME_PARTY_MAIN');

        Button[0].Visible := true;
        Button[1].Visible := false;
        Button[2].Visible := false;
        Button[3].Visible := false;

        SelectsS[0].Visible := false;
        SelectsS[1].Visible := false;
        SelectsS[2].Visible := false;

        Button[0].Text[0].Text := Language.Translate('SONG_MENU_PLAY');
      end;
    SM_Jukebox:
      begin
        ID := 'ID_021';
        CurMenu := sMenu;

        Text[0].Text := Language.Translate('SONG_MENU_NAME_JUKEBOX');

        UpdateJukeboxButtons();

        Button[0].Visible := (Ini.TabsAtStartup = 1);
        Button[3].Visible := false;
        Button[4].Visible := true;

        SelectsS[0].Visible := false;
        SelectsS[1].Visible := false;
        SelectsS[2].Visible := false;

        Button[1].Text[0].Text := Language.Translate('SONG_MENU_ADD_SONG');
        Button[2].Text[0].Text := Language.Translate('SONG_MENU_DELETE_SONG');

        Button[4].Text[0].Text := Language.Translate('SONG_MENU_START_JUKEBOX');

        if (Ini.TabsAtStartup = 1) then
          Interaction := 0
        else
          Interaction := 1;

      end;
  end;
  UpdateInstrumentalButton;
  if not Help.SetHelpID(ID) then
    Log.LogWarn('No Entry for Help-ID ' + ID, 'ScreenSongMenu');
end;

procedure TScreenSongMenu.HandleReturn;
var
  I: integer;
  SDL_ModState:  Word;
begin
  SDL_ModState := SDL_GetModState and (KMOD_LSHIFT + KMOD_RSHIFT
    + KMOD_LCTRL + KMOD_RCTRL + KMOD_LALT  + KMOD_RALT);
  case CurMenu of
    SM_Main:
      begin
        case Interaction of
          0: // button 1
            begin
              MenuShow(SM_Song);
            end;

          1: // button 2
            begin
              MenuShow(SM_Medley);
            end;

          2: // button 3
            begin
              HandleInstrumental;
            end;

          3: // selectslide 1
            begin
              //Dummy
            end;

          4: // selectslide 2
            begin
              //Dummy
            end;

          5: // selectslide 3
            begin
              //Dummy
            end;

          6: // button 4
            begin
              // show refresh scores menu
              MenuShow(SM_Refresh_Scores);
              ScreenSong.StopMusicPreview();
              ScreenSong.StopVideoPreview();
            end;
          7: // button 5
            begin
              Visible := false;
              ScreenUSDB.ShowBrowser;
            end;
          end;
      end;

      SM_Song:
      begin
        case Interaction of
          0: // button 1
            begin

              //if (CatSongs.Song[ScreenSong.Interaction].isDuet and ((PlayersPlay=1) or
              //   (PlayersPlay=3) or (PlayersPlay=6))) then
              //  ScreenPopupError.ShowPopup(Language.Translate('SING_ERROR_DUET_NUM_PLAYERS'))
              //else
              //begin
                ScreenSong.StartSong;
                Visible := false;
              //end;
            end;

          1: // button 2
            begin
              // select new players then sing:
              ScreenSong.SelectPlayers;
              Visible := false;
            end;

          2: // button 3
            begin
              // show add to playlist menu
              MenuShow(SM_Playlist_Add);
            end;

          3: // selectslide 1
            begin
              //Dummy
            end;

          4: // selectslide 2
            begin
              //Dummy
            end;

          5: // selectslide 3
            begin
              //Dummy
            end;

          6: // button 4
            begin
              ScreenSong.OpenEditor;
              Visible := false;
            end;

          7: // button 5
            begin
              // show main menu
              MenuShow(SM_Main);
            end;
          end;
      end;

    SM_Medley:
      begin
        Case Interaction of
          0: //Button 1
            begin
              ScreenSong.MakeMedley := true;
              ScreenSong.StartMedley(99, msCalculated);

              Visible := False;
            end;

          1: //Button 2
            begin
              SetLength(PlaylistMedley.Song, Length(PlaylistMedley.Song)-1);
              PlaylistMedley.NumMedleySongs := Length(PlaylistMedley.Song);

              if Length(PlaylistMedley.Song)=0 then
                ScreenSong.MakeMedley := false;

              Visible := False;
            end;

          2: //Button 3
            begin

              if ScreenSong.MakeMedley then
              begin
                ScreenSong.Mode := smMedley;
                PlaylistMedley.CurrentMedleySong := 0;

                //Do the Action that is specified in Ini
                case Ini.OnSongClick of
                  0: FadeTo(@ScreenSing);
                  1: ScreenSong.SelectPlayers;
                  2: FadeTo(@ScreenSing);
                end;
              end
              else
                ScreenSong.StartMedley(0, msCalculated);

              Visible := False;

            end;

          6: //Button 4
            begin
              ScreenSong.StartMedley(5, msCalculated);
              Visible := False;
            end;

          7: // button 5
            begin
              // show main menu
              MenuShow(SM_Main);
            end;
        end;
      end;

    SM_PlayList:
      begin
        Visible := false;
        case Interaction of
          0: // button 1
            begin
              ScreenSong.StartSong;
              Visible := false;
            end;

          1: // button 2
            begin
              // select new players then sing:
              ScreenSong.SelectPlayers;
              Visible := false;
            end;

          2: // button 3
            begin
              // show add to playlist menu
              MenuShow(SM_Playlist_DelItem);
            end;

          3: // selectslide 1
            begin
              // dummy
            end;

          4: // selectslide 2
            begin
              // dummy
            end;

          5: // selectslide 3
            begin
              // dummy
            end;

          6: // button 4
            begin
              ScreenSong.OpenEditor;
              Visible := false;
            end;
          7: // button 5
            begin
              Visible := true;
              HandleInstrumental;
            end;
        end;
      end;

    SM_Playlist_Add:
      begin
        case Interaction of
          0: // button 1
            begin
              MenuShow(SM_Playlist_New);
            end;

          4: // selectslide 3
            begin
              // dummy
            end;

          6: // button 4
            begin
              PlaylistMan.AddItem(ScreenSong.Interaction, SelectValue3);
              Visible := false;
            end;

          7: // button 5
            begin
              // show song menu
              MenuShow(SM_Song);
            end;
        end;
      end;

      SM_Playlist_New:
      begin
        case Interaction of
          1: // button 1
            begin
              // nothing, button for entering name
            end;

          6: // button 4
            begin
              // create playlist and add song
              PlaylistMan.AddItem(
              ScreenSong.Interaction,
              PlaylistMan.AddPlaylist(Button[1].Text[0].Text));
              Visible := false;
            end;

          7: // button 5
            begin
              // show add song menu
              MenuShow(SM_Playlist_Add);
            end;

        end;
      end;

    SM_Playlist_DelItem:
      begin
        Visible := false;
        case Interaction of
          0: // button 1
            begin
              // delete
              PlayListMan.DelItem(PlayListMan.GetIndexbySongID(ScreenSong.Interaction));
              Visible := false;
            end;

          6: // button 4
            begin
              MenuShow(SM_Playlist);
            end;
        end;
      end;

    SM_Playlist_Load:
      begin
        case Interaction of
          0: // button 1 (Delete playlist)
            begin
              MenuShow(SM_Playlist_Del);
            end;
          6: // button 4
            begin
              // load playlist
              PlaylistMan.ReloadPlaylist(SelectValue3);
              PlaylistMan.SetPlayList(SelectValue3);
              Visible := false;
              ScreenSong.SetScrollRefresh;
            end;
        end;
      end;

    SM_Playlist_Del:
      begin
        Visible := false;
        case Interaction of
          0: // button 1
            begin
              // delete
              PlayListMan.DelPlaylist(PlaylistMan.CurPlayList);
              Visible := false;
            end;

          6: // button 4
            begin
              MenuShow(SM_Playlist_Load);
            end;
        end;
      end;

    SM_Party_Main:
      begin
        case Interaction of
          0: // button 1
            begin
              // start singing
              Party.CallAfterSongSelect;
              Visible := false;
            end;

          6: // button 4
            begin
              // joker
              MenuShow(SM_Party_Joker);
            end;
        end;
      end;

    SM_Party_Free_Main:
    begin
      case Interaction of
        0: // button 1
          begin
            // start singing
            Party.CallAfterSongSelect;
            Visible := false;
          end;
      end;
    end;

    SM_Party_Joker:
      begin
        Visible := false;
        case Interaction of
          0: // button 1
            begin
              // joker team 1
              ScreenSong.DoJoker(0, SDL_ModState);
            end;

          1: // button 2
            begin
              // joker team 2
              ScreenSong.DoJoker(1, SDL_ModState);
            end;

          2: // button 3
            begin
              // joker team 3
              ScreenSong.DoJoker(2, SDL_ModState);
            end;

          6: // button 4
            begin
              // cancel... (go back to old menu)
              MenuShow(SM_Party_Main);
            end;
        end;
      end;

    SM_Refresh_Scores:
      begin
        case Interaction of
          7: // button 5
            begin
              if (Length(ISelections3)>=1) then
              begin
                // Refresh Scores
                Visible := false;
                ScreenPopupScoreDownload.ShowPopup(SelectValue1, SelectValue2, SelectValue3);
              end
              else
              begin
                Button[2].Selectable := true;
                MenuShow(SM_Main);
              end;
            end;
        end;
      end;

    SM_Jukebox:
      begin
        Case Interaction of
          0: //Button 1
            begin

              if (Songs.SongList.Count > 0) then
              begin
                if CatSongs.Song[ScreenSong.Interaction].Main then
                begin // clicked on Category Button
                  //Show Cat in Top Left Mod
                  ScreenSong.ShowCatTL(ScreenSong.Interaction);

                  CatSongs.ClickCategoryButton(ScreenSong.Interaction);

                  //Show Wrong Song when Tabs on Fix
                  ScreenSong.SelectNext;
                  ScreenSong.FixSelected;
                end
                else
                begin
                  //Find Category
                  I := ScreenSong.Interaction;
                  while (not CatSongs.Song[I].Main) do
                  begin
                    Dec(I);
                    if (I < 0) then
                      break;
                  end;

                  if (I <= 1) then
                    ScreenSong.Interaction := High(CatSongs.Song)
                  else
                    ScreenSong.Interaction := I - 1;

                  //Stop Music
                  ScreenSong.StopMusicPreview();

                  CatSongs.ShowCategoryList;

                  //Show Cat in Top Left Mod
                  ScreenSong.HideCatTL;

                  //Show Wrong Song when Tabs on Fix
                  ScreenSong.SelectNext;
                  ScreenSong.FixSelected;
                end;
              end;

              UpdateJukeboxButtons;
            end;

          1: //Button 2
            begin
              if (not CatSongs.Song[Interaction].Main) then
                ScreenJukebox.AddSongToJukeboxList(ScreenSong.Interaction);

              UpdateJukeboxButtons;
            end;

          2: //Button 3
            begin
              SetLength(ScreenJukebox.JukeboxSongsList, Length(ScreenJukebox.JukeboxSongsList)-1);
              SetLength(ScreenJukebox.JukeboxVisibleSongs, Length(ScreenJukebox.JukeboxVisibleSongs)-1);

              if (Length(ScreenJukebox.JukeboxSongsList) = 0) then
                Interaction := 1;

              UpdateJukeboxButtons;
            end;

          7: //Button 4
            begin
              if (Length(ScreenJukebox.JukeboxSongsList) > 0) then
              begin
                ScreenJukebox.CurrentSongID := ScreenJukebox.JukeboxVisibleSongs[0];
                FadeTo(@ScreenJukebox);
                Visible := False;
              end
              else
                ScreenPopupError.ShowPopup(Language.Translate('PARTY_MODE_JUKEBOX_NO_SONGS'));
            end;
        end;
      end;

  end;
end;

end.
