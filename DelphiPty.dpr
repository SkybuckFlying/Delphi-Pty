library DelphiPty;

{
  In 2026 (Delphi 12+), it is highly recommended to include SimpleShareMem
  if you are passing strings/records between different Delphi modules.
}
uses
  System.SysUtils,
  PtyCore in 'PtyCore.pas';

{$R *.res}

{
  Explicitly export functions.
  The 'name' clause ensures that the exported symbol does not have
  any compiler-specific mangling (like @Pty_Init$qqrv).
}
exports
  Pty_Init   name 'Pty_Init',
  Pty_Create name 'Pty_Create',
  Pty_Write  name 'Pty_Write',
  Pty_Resize name 'Pty_Resize',
  Pty_Close  name 'Pty_Close',
  Pty_Kill   name 'Pty_Kill',
  Pty_IsAlive name 'Pty_IsAlive',
  Pty_GetExitCode name 'Pty_GetExitCode';

begin
  // Library initialization code (if any)
end.
