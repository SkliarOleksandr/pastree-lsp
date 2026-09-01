object PasTreeSettingsForm: TPasTreeSettingsForm
  Left = 0
  Top = 0
  BorderIcons = [biSystemMenu]
  BorderStyle = bsDialog
  Caption = 'PasTree Settings'
  ClientHeight = 677
  ClientWidth = 462
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poMainFormCenter
  TextHeight = 15
  object bvlHeader: TBevel
    Left = 0
    Top = 92
    Width = 462
    Height = 2
    Align = alTop
    Shape = bsTopLine
    ExplicitWidth = 460
  end
  object pnlHeader: TPanel
    Left = 0
    Top = 0
    Width = 462
    Height = 92
    Align = alTop
    BevelOuter = bvNone
    ParentBackground = False
    TabOrder = 0
    object lblProduct: TLabel
      Left = 16
      Top = 14
      Width = 118
      Height = 25
      Caption = 'PasTree LSP'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clWindowText
      Font.Height = -19
      Font.Name = 'Segoe UI'
      Font.Style = [fsBold]
      ParentFont = False
    end
    object lblVersion: TLabel
      Left = 18
      Top = 45
      Width = 44
      Height = 15
      Caption = 'Version'
    end
    object lblBuilt: TLabel
      Left = 18
      Top = 64
      Width = 27
      Height = 15
      Caption = 'Built'
    end
    object lnkHome: TLinkLabel
      Left = 197
      Top = 45
      Width = 247
      Height = 19
      Caption =
        '<a href="https://github.com/SkliarOleksandr/pastree-lsp">github.' +
        'com/SkliarOleksandr/pastree-lsp</a>'
      TabOrder = 0
      OnLinkClick = lnkHomeLinkClick
    end
  end
  object gbOverrides: TGroupBox
    Left = 16
    Top = 108
    Width = 430
    Height = 352
    Caption = ' Overrides '
    TabOrder = 1
    object lblCtrlClickHint: TLabel
      Left = 35
      Top = 45
      Width = 377
      Height = 30
      Caption =
        'Ctrl+Click and the editor menu item resolve through PasTree. The men' +
        'u half only changes at the next IDE restart.'
      WordWrap = True
    end
    object chkCtrlClick: TCheckBox
      Left = 16
      Top = 24
      Width = 396
      Height = 17
      Caption = 'Find Declaration (Ctrl+Click and the editor menu)'
      Checked = True
      State = cbChecked
      TabOrder = 0
    end
    object lblDeclImplToggleHint: TLabel
      Left = 35
      Top = 110
      Width = 377
      Height = 30
      Caption =
        'Off hands the keystroke back to the IDE, which runs its own decla' +
        'ration/implementation jump.'
      WordWrap = True
    end
    object lblRenameHint: TLabel
      Left = 35
      Top = 175
      Width = 377
      Height = 30
      Caption =
        'Renames a symbol across the project and lists every changed line ' +
        'in its own Messages tab. Off hides the command entirely.'
      WordWrap = True
    end
    object lblBlockCompletionHint: TLabel
      Left = 35
      Top = 240
      Width = 377
      Height = 30
      Caption =
        'Inserts the missing end;/until ; on the next line when Enter is p' +
        'ressed right after an unclosed block opener.'
      WordWrap = True
    end
    object chkDeclImplToggle: TCheckBox
      Left = 16
      Top = 89
      Width = 396
      Height = 17
      Caption = 'Ctrl+Shift+Up / Ctrl+Shift+Down declaration'#8596'implementation jump'
      Checked = True
      State = cbChecked
      TabOrder = 1
    end
    object chkRename: TCheckBox
      Left = 16
      Top = 154
      Width = 396
      Height = 17
      Caption = 'Rename (Ctrl+Shift+E)'
      Checked = True
      State = cbChecked
      TabOrder = 2
    end
    object chkBlockCompletion: TCheckBox
      Left = 16
      Top = 219
      Width = 396
      Height = 17
      Caption = 'Block completion (Enter after begin/try/case/repeat)'
      Checked = True
      State = cbChecked
      TabOrder = 3
    end
    object lblClassCompleteHint: TLabel
      Left = 35
      Top = 305
      Width = 377
      Height = 30
      Caption =
        'Implements what is declared, and first mirrors a changed signatur' +
        'e onto the routine'#39's other half. Off leaves the key to the IDE.'
      WordWrap = True
    end
    object chkClassComplete: TCheckBox
      Left = 16
      Top = 284
      Width = 396
      Height = 17
      Caption = 'Complete Class At Cursor (Ctrl+Shift+C)'
      Checked = True
      State = cbChecked
      TabOrder = 4
    end
  end
  object gbLogging: TGroupBox
    Left = 16
    Top = 468
    Width = 430
    Height = 150
    Caption = ' Logging '
    TabOrder = 2
    object lblLoggingHint: TLabel
      Left = 35
      Top = 45
      Width = 377
      Height = 30
      Caption =
        'Writes pastree-lsp.log next to the project file - the handshake, ' +
        'the analysis timings and every failed navigation. Off writes noth' +
        'ing.'
      WordWrap = True
    end
    object lblAdvancedLoggingHint: TLabel
      Left = 35
      Top = 110
      Width = 377
      Height = 30
      Caption =
        'Adds every search path, define, namespace and unit alias to the l' +
        'og. Off keeps the one-line summary with the counts.'
      WordWrap = True
    end
    object chkLogging: TCheckBox
      Left = 16
      Top = 24
      Width = 396
      Height = 17
      Caption = 'Enable logging'
      Checked = True
      State = cbChecked
      TabOrder = 0
      OnClick = chkLoggingClick
    end
    object chkAdvancedLogging: TCheckBox
      Left = 16
      Top = 89
      Width = 396
      Height = 17
      Caption = 'Advanced logging (paths, defines, namespaces, aliases)'
      TabOrder = 1
    end
  end
  object btnOK: TButton
    Left = 270
    Top = 637
    Width = 85
    Height = 27
    Caption = 'OK'
    Default = True
    ModalResult = 1
    TabOrder = 3
  end
  object btnCancel: TButton
    Left = 361
    Top = 637
    Width = 85
    Height = 27
    Cancel = True
    Caption = 'Cancel'
    ModalResult = 2
    TabOrder = 4
  end
end
