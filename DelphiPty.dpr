library DelphiPty;

uses
  System.SysUtils,
  System.Classes,
  PtyCore in 'PtyCore.pas';

{$R *.res}

exports
  Pty_Init,
  Pty_Create,
  Pty_Write,
  Pty_Resize,
  Pty_Close,
  Pty_Kill,
  Pty_IsAlive,
  Pty_GetExitCode;

begin
end.