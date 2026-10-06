unit UInstrumental;

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

interface

uses
  UPath, USong;

type
  TInstrumentalState = (isMissing, isQueued, isProcessing, isReady, isFailed, isStalled);
  TInstrumentalProgress = record
    State: TInstrumentalState;
    Stage, ErrorText, Confidence: UTF8String;
    Percent, ElapsedSeconds, RemainingSeconds: integer;
    QueuePosition, WaitSeconds, ProcessingSeconds, JobsWaiting: integer;
    ChunksDone, ChunksTotal: integer;
  end;

function InstrumentalQueuePath: IPath;
function InstrumentalJobPath(Song: TSong): IPath;
function InstrumentalState(Song: TSong; out ErrorText: UTF8String): TInstrumentalState;
function ReadInstrumentalProgress(Song: TSong): TInstrumentalProgress;
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
  Progress: TInstrumentalProgress;
begin
  Progress := ReadInstrumentalProgress(Song);
  ErrorText := Progress.ErrorText;
  Result := Progress.State;
end;

function ReadInstrumentalProgress(Song: TSong): TInstrumentalProgress;
var
  JobPath, StatusPath, Track: IPath;
  Status: TUnicodeMemIniFile;
  Stage: string;
  Heartbeat, StatusTime: TDateTime;
  ProgressAge, ProgressTimeout: integer;
begin
  Result.State := isMissing;
  Result.Stage := '';
  Result.ErrorText := '';
  Result.Confidence := '';
  Result.Percent := -1;
  Result.ElapsedSeconds := -1;
  Result.RemainingSeconds := -1;
  Result.WaitSeconds := -1;
  Result.ProcessingSeconds := -1;
  Result.QueuePosition := 0;
  Result.JobsWaiting := 0;
  Result.ChunksDone := 0;
  Result.ChunksTotal := 0;
  ProgressAge := 0;
  ProgressTimeout := 0;
  if (Song = nil) or Song.Main then
    Exit;

  JobPath := InstrumentalJobPath(Song);
  StatusPath := JobPath.SetExtension('.status');
  if StatusPath.IsFile then
  begin
    Status := TUnicodeMemIniFile.Create(StatusPath, true);
    try
      Stage := Status.ReadString('Job', 'Stage', '');
      Result.Stage := Stage;
      Result.Percent := Status.ReadInteger('Job', 'Percent', -1);
      Result.ElapsedSeconds := Status.ReadInteger('Job', 'ElapsedSeconds', -1);
      Result.RemainingSeconds := Status.ReadInteger('Job', 'EstimatedRemainingSeconds', -1);
      Result.QueuePosition := Status.ReadInteger('Job', 'QueuePosition', 0);
      Result.WaitSeconds := Status.ReadInteger('Job', 'EstimatedWaitSeconds', -1);
      Result.ProcessingSeconds := Status.ReadInteger('Job', 'EstimatedProcessingSeconds', -1);
      Result.JobsWaiting := Status.ReadInteger('Job', 'JobsWaiting', 0);
      Result.ChunksDone := Status.ReadInteger('Job', 'ChunksDone', 0);
      Result.ChunksTotal := Status.ReadInteger('Job', 'ChunksTotal', 0);
      Result.Confidence := Status.ReadString('Job', 'Confidence', '');
      ProgressAge := Status.ReadInteger('Job', 'ProgressAgeSeconds', 0);
      ProgressTimeout := Status.ReadInteger('Job', 'ProgressTimeoutSeconds', 0);
      if Stage = 'ready' then
      begin
        Track := Path(UTF8String(Status.ReadString('Job', 'Instrumental', '')));
        if not Track.IsUnset and Track.GetName.Equals(Track) and Song.Path.Append(Track).IsFile then
        begin
          Song.Karaoke := Track;
          Track := Path(UTF8String(Status.ReadString('Job', 'Vocals', '')));
          if not Track.IsUnset and Track.GetName.Equals(Track) and Song.Path.Append(Track).IsFile then
            Song.Vocals := Track;
          Result.State := isReady;
        end;
      end
      else if (Stage = 'processing') or (Stage = 'preparing') or (Stage = 'reading') or
              (Stage = 'separating') or (Stage = 'encoding') or (Stage = 'saving') then
        Result.State := isProcessing
      else if Stage = 'queued' then
        Result.State := isQueued
      else if Stage = 'failed' then
      begin
        Result.State := isFailed;
        Result.ErrorText := UTF8String(Status.ReadString('Job', 'Error', ''));
      end;
    finally
      Status.Free;
    end;
  end;
  if JobPath.IsFile and (Result.State in [isMissing, isFailed]) then
  begin
    Result.State := isQueued;
    Result.Stage := 'queued';
    Result.ElapsedSeconds := 0;
    Result.Percent := -1;
    Result.RemainingSeconds := -1;
    Result.ErrorText := '';
  end;
  if Assigned(Song.Karaoke) and not Song.Karaoke.IsUnset and Song.Path.Append(Song.Karaoke).IsFile then
  begin
    Result.State := isReady;
    Result.Percent := 100;
    Result.RemainingSeconds := 0;
  end;
  if Result.State in [isQueued, isProcessing] then
  begin
    if not FileSystem.FileAge(InstrumentalQueuePath.Append('heartbeat'), Heartbeat) or
       ((Now - Heartbeat) * 86400 > 15) or
       (FileSystem.FileAge(StatusPath, StatusTime) and ((Now - StatusTime) * 86400 > 15)) or
       ((ProgressTimeout > 0) and (ProgressAge > ProgressTimeout)) then
    begin
      Result.State := isStalled;
      Result.RemainingSeconds := -1;
      Result.WaitSeconds := -1;
      Result.ErrorText := 'INSTRUMENTAL_WORKER_STALLED';
    end;
  end;
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
  if State = isStalled then
    Exit;
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
