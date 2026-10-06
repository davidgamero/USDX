unit UInstrumental;

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

interface

uses
  UPath, USong;

type
  TInstrumentalState = (isMissing, isQueued, isProcessing, isReady, isFailed);

function InstrumentalQueuePath: IPath;
function InstrumentalJobPath(Song: TSong): IPath;
function InstrumentalState(Song: TSong; out ErrorText: UTF8String): TInstrumentalState;
function QueueInstrumental(Song: TSong; out ErrorText: UTF8String): boolean;

implementation

uses
  Classes, SysUtils, MD5, UFilesystem, UPlatform;

function InstrumentalQueuePath: IPath;
var
  OverridePath: string;
begin
  OverridePath := GetEnvironmentVariable('USDX_INSTRUMENTAL_QUEUE');
  if OverridePath <> '' then
    Result := Path(OverridePath)
  else
    Result := Platform.GetGameUserPath.Append('instrumentals');
end;

function InstrumentalJobPath(Song: TSong): IPath;
var
  Chart: UTF8String;
begin
  Chart := Song.Path.Append(Song.FileName).GetAbsolutePath.ToUTF8;
  Result := InstrumentalQueuePath.Append(MD5Print(MD5String(Chart)) + '.job');
end;

function InstrumentalState(Song: TSong; out ErrorText: UTF8String): TInstrumentalState;
var
  JobPath, StatusPath, Track: IPath;
  Status: TUnicodeMemIniFile;
  Stage: string;
begin
  Result := isMissing;
  ErrorText := '';
  if (Song = nil) or Song.Main then
    Exit;
  if Assigned(Song.Karaoke) and not Song.Karaoke.IsUnset and Song.Path.Append(Song.Karaoke).IsFile then
  begin
    Result := isReady;
    Exit;
  end;

  JobPath := InstrumentalJobPath(Song);
  StatusPath := JobPath.SetExtension('.status');
  if StatusPath.IsFile then
  begin
    Status := TUnicodeMemIniFile.Create(StatusPath, true);
    try
      Stage := Status.ReadString('Job', 'Stage', '');
      if Stage = 'ready' then
      begin
        Track := Path(UTF8String(Status.ReadString('Job', 'Instrumental', '')));
        if not Track.IsUnset and Track.GetName.Equals(Track) and Song.Path.Append(Track).IsFile then
        begin
          Song.Karaoke := Track;
          Track := Path(UTF8String(Status.ReadString('Job', 'Vocals', '')));
          if not Track.IsUnset and Track.GetName.Equals(Track) and Song.Path.Append(Track).IsFile then
            Song.Vocals := Track;
          Result := isReady;
        end;
      end
      else if Stage = 'processing' then
        Result := isProcessing
      else if Stage = 'failed' then
      begin
        Result := isFailed;
        ErrorText := UTF8String(Status.ReadString('Job', 'Error', ''));
      end;
    finally
      Status.Free;
    end;
  end;
  if JobPath.IsFile and (Result in [isMissing, isFailed]) then
    Result := isQueued;
end;

function QueueInstrumental(Song: TSong; out ErrorText: UTF8String): boolean;
var
  JobPath, TempPath: IPath;
  Job: TUnicodeMemIniFile;
  Heartbeat: TDateTime;
  State: TInstrumentalState;
begin
  Result := false;
  ErrorText := '';
  if (Song = nil) or Song.Main then
    Exit;
  State := InstrumentalState(Song, ErrorText);
  if State in [isQueued, isProcessing, isReady] then
  begin
    Result := true;
    Exit;
  end;
  if not FileSystem.FileAge(InstrumentalQueuePath.Append('heartbeat'), Heartbeat) or
     ((Now - Heartbeat) * 86400 > 15) then
  begin
    ErrorText := 'INSTRUMENTAL_WORKER_UNAVAILABLE';
    Exit;
  end;
  if Song.Audio.IsUnset or not Song.Path.Append(Song.Audio).IsFile then
  begin
    ErrorText := 'INSTRUMENTAL_AUDIO_MISSING';
    Exit;
  end;

  JobPath := InstrumentalJobPath(Song);
  TempPath := JobPath.SetExtension('.tmp');
  try
    Job := TUnicodeMemIniFile.Create(TempPath, true);
    try
      Job.WriteString('Song', 'Chart', Song.Path.Append(Song.FileName).GetAbsolutePath.ToUTF8);
      Job.WriteString('Song', 'Audio', Song.Path.Append(Song.Audio).GetAbsolutePath.ToUTF8);
      Job.UpdateFile;
    finally
      Job.Free;
    end;
    if not TempPath.Rename(JobPath) then
      raise Exception.Create('Could not publish instrumental request');
    ErrorText := '';
    Result := true;
  except
    on E: Exception do
      ErrorText := E.Message;
  end;
  if TempPath.IsFile then
    TempPath.DeleteFile;
end;

end.
