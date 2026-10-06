program test_song_refresh;

{$mode Delphi}
{$codepage utf8}

uses
  {$IFDEF UNIX}
  cthreads, cwstring,
  {$ENDIF}
  Classes, SysUtils, SDL2, SDL2_image, SQLite3, SQLiteTable3, dglOpenGL,
  UPath, UPathUtils, ULog, UIni, UCommandLine,
  USong, USongs, UPlaylist, UCatCovers;

var
  Root, Nested: IPath;
  OriginalSong: TSong;
  Event: TSDL_Event;
  I, SongIndex: integer;

procedure Check(Condition: boolean; const MessageText: string);
begin
  if not Condition then
    raise Exception.Create(MessageText);
end;

procedure WriteFile(const Filename: IPath; const Contents: UTF8String);
var
  Stream: TBinaryFileStream;
begin
  Stream := TBinaryFileStream.Create(Filename, fmCreate);
  try
    if Length(Contents) > 0 then
      Stream.WriteBuffer(Contents[1], Length(Contents));
  finally
    Stream.Free;
  end;
end;

procedure WriteSong(const Dir: IPath; const Artist: UTF8String);
begin
  WriteFile(Dir.Append('song.txt'),
    '#ENCODING:UTF8' + LineEnding +
    '#ARTIST:' + Artist + LineEnding +
    '#TITLE:Refresh fixture' + LineEnding +
    '#MP3:audio.wav' + LineEnding +
    '#BPM:120' + LineEnding +
    '#GAP:0' + LineEnding +
    ': 0 4 0 Test' + LineEnding + 'E' + LineEnding);
end;

begin
  Check(ParamCount = 1, 'Pass an empty temporary directory for fixtures');
  Root := Path(UTF8String(ParamStr(1))).GetAbsolutePath;
  Check(Root.IsDirectory, 'Fixture directory must exist');
  Log := TLog.Create;
  Params := TCMDParams.Create;
  Ini := TIni.Create;
  Ini.Sorting := Ord(sArtist);
  SongPaths := TInterfaceList.Create;
  SongPaths.Add(Root);
  CoverPaths := TInterfaceList.Create;
  PlaylistPath := Root;
  CatCovers := TCatCovers.Create;
  Check(SDL_Init($00004000 {SDL_INIT_EVENTS}) = 0, 'SDL events initialization failed');

  Songs := TSongs.Create;
  CatSongs := TCatSongs.Create;
  Check(Songs.SongList.Count = 0, 'Expected an empty initial library');
  Check(CatSongs.VisibleSongs = 0, 'Empty catalog must have zero visible songs');
  Check(Songs.ScanForNewSongs = 0, 'Empty rescan must add no songs');

  WriteSong(Root, 'Zulu');
  Check(Songs.ScanForNewSongs = 0, 'Missing audio must not enter the catalog');
  // The header scanner only checks existence; audio decoding is tested by the game.
  WriteFile(Root.Append('audio.wav'), 'fixture');
  Check(Songs.ScanForNewSongs = 1, 'Completed download was not retried');
  OriginalSong := TSong(Songs.SongList[0]);
  Check(Songs.ScanForNewSongs = 0, 'Repeated scan duplicated a song');

  CatSongs.Refresh;
  PlayListMan := TPlaylistManager.Create;
  SetLength(PlayListMan.Playlists, 1);
  SetLength(PlayListMan.Playlists[0].Items, 1);
  PlayListMan.Playlists[0].Items[0].Artist := OriginalSong.Artist;
  PlayListMan.Playlists[0].Items[0].Title := OriginalSong.Title;
  PlayListMan.Playlists[0].Items[0].SongID := 0;

  Nested := Root.Append('Beyoncé - new download');
  Check(Nested.CreateDirectory, 'Could not create nested fixture');
  SongPaths.Add(Nested); // overlapping song roots must not duplicate additions
  WriteFile(Nested.Append('song.txt'), '#ARTIST:incomplete');
  WriteFile(Nested.Append('audio.wav'), 'fixture');
  Check(Songs.ScanForNewSongs = 0, 'Incomplete header must be retried later');
  WriteSong(Nested, 'Alpha');
  FillChar(Event, SizeOf(Event), 0);
  Event.type_ := SDL_QUITEV;
  Check(SDL_PushEvent(@Event) = 1, 'Could not queue SDL event');
  Check(Songs.ScanForNewSongs = 1, 'Nested Unicode path was not imported exactly once');
  Check(SDL_PollEvent(@Event) = 1, 'Refresh swallowed a queued SDL event');
  Check(Event.type_ = SDL_QUITEV, 'Refresh changed a queued SDL event');

  Ini.Tabs := 1;
  Ini.TabsAtStartup := 1;
  for I := 1 to 5 do
  begin
    Check(Songs.ScanForNewSongs = 0, 'Unchanged library must not grow');
    CatSongs.Refresh;
    PlayListMan.RefreshSongIndices;
    SongIndex := PlayListMan.Playlists[0].Items[0].SongID;
    Check(CatSongs.Song[SongIndex] = OriginalSong, 'Playlist lost its original song after sorting');
    Check(Songs.SongList.Count = 2, 'Category rebuild changed real songs');
    Check(Length(CatSongs.Song) = 4, 'Category buttons accumulated on refresh');
  end;
  Check(CatSongs.SetFilter('Alpha', fltArtist) = 1, 'Search did not include the new song');
  Check(not Songs.Processing, 'Refresh left the catalog busy');
  WriteLn('PASS: empty library, incremental additions, incomplete downloads, Unicode paths, overlapping roots, repeat scans, SDL events, categories, playlists and search');
  // The process owns these temporary fixtures and exits without starting the game.
end.
