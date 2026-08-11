# AnyDesk - Backup e Limpeza

Script PowerShell para realizar uma limpeza da instalação do AnyDesk preservando o ID/Alias do dispositivo.

## O que o script faz

- Encerra o AnyDesk e seus serviços.
- Localiza o arquivo `service.conf`.
- Faz backup automático das configurações.
- Valida o backup antes de continuar.
- Limpa configurações, cache e arquivos temporários.
- Restaura o `service.conf` para preservar o ID/Alias.
- Inicia novamente o AnyDesk.
- Mantém uma cópia de segurança em `C:\AnyDesk_Backup`.

## Como executar

Abra o **PowerShell como Administrador**.

Acesse a pasta onde está o script:

```powershell
cd "C:\Users\SEU_USUARIO\Downloads"


Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

.\AnyDesk_Backup_Limpeza_Restauracao.ps1


Backup: C:\AnyDesk_Backup\
