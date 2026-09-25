object PasTreeSettingsForm: TPasTreeSettingsForm
  Left = 0
  Top = 0
  BorderIcons = [biSystemMenu]
  BorderStyle = bsDialog
  Caption = 'PasTree Settings'
  ClientHeight = 605
  ClientWidth = 500
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
    Width = 500
    Height = 2
    Align = alTop
    Shape = bsTopLine
    ExplicitWidth = 460
  end
  object pnlHeader: TPanel
    Left = 0
    Top = 0
    Width = 500
    Height = 92
    Align = alTop
    BevelOuter = bvNone
    ParentBackground = False
    TabOrder = 0
    object imgLogo: TImage
      Left = 16
      Top = 16
      Width = 24
      Height = 24
      Transparent = True
    end
    object lblProduct: TLabel
      Left = 48
      Top = 14
      Width = 106
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
      Left = 50
      Top = 45
      Width = 38
      Height = 15
      Caption = 'Version'
    end
    object lblBuilt: TLabel
      Left = 50
      Top = 64
      Width = 24
      Height = 15
      Caption = 'Built'
    end
    object lnkHome: TLinkLabel
      Left = 197
      Top = 41
      Width = 215
      Height = 19
      Caption =
        '<a href="https://github.com/SkliarOleksandr/pastree-lsp">github.' +
        'com/SkliarOleksandr/pastree-lsp</a>'
      TabOrder = 0
      OnLinkClick = lnkHomeLinkClick
    end
    object lnkHomePasTree: TLinkLabel
      Left = 198
      Top = 60
      Width = 253
      Height = 19
      Caption =
        '<a href="https://github.com/SkliarOleksandr/object-pascal-tree">' +
        'github.com/SkliarOleksandr/object-pascal-tree</a>'
      TabOrder = 1
      OnLinkClick = lnkHomeLinkClick
    end
  end
  object pgcSettings: TPageControl
    Left = 12
    Top = 106
    Width = 476
    Height = 440
    ActivePage = tsNavigation
    TabOrder = 1
    object tsNavigation: TTabSheet
      Caption = 'Navigation'
      object lblCtrlClickHint: TLabel
        Left = 35
        Top = 41
        Width = 405
        Height = 30
        Caption =
          'Ctrl+Click and the editor menu item resolve through PasTree. The' +
          ' menu half only changes at the next IDE restart.'
        WordWrap = True
      end
      object lblDeclImplToggleHint: TLabel
        Left = 35
        Top = 111
        Width = 405
        Height = 30
        Caption =
          'Off hands the keystroke back to the IDE, which runs its own decl' +
          'aration/implementation jump.'
        WordWrap = True
      end
      object lblFindAllHint: TLabel
        Left = 35
        Top = 181
        Width = 405
        Height = 60
        Caption =
          'References, Overrides, Implementations, Descendants, Assignments,' +
          ' Creations and Destructions of the symbol under the cursor, across' +
          ' the whole project group, each in its own Messages tab. Items that' +
          ' do not apply at the cursor are greyed. Off hides the submenu.'
        WordWrap = True
      end
      object chkCtrlClick: TCheckBox
        Left = 16
        Top = 20
        Width = 430
        Height = 17
        Caption = 'Find Declaration (Ctrl+Click and the editor menu)'
        Checked = True
        State = cbChecked
        TabOrder = 0
      end
      object chkDeclImplToggle: TCheckBox
        Left = 16
        Top = 90
        Width = 430
        Height = 17
        Caption = 'Ctrl+Shift+Up / Ctrl+Shift+Down declaration'#8596'implementation jump'
        Checked = True
        State = cbChecked
        TabOrder = 1
      end
      object chkFindAll: TCheckBox
        Left = 16
        Top = 160
        Width = 430
        Height = 17
        Caption = 'Find All submenu (editor menu)'
        Checked = True
        State = cbChecked
        TabOrder = 2
      end
      object lblGoToHint: TLabel
        Left = 35
        Top = 271
        Width = 405
        Height = 45
        Caption =
          'A picker over the declarations of the current unit and the' +
          ' project - type a name or a line number. Off hands Ctrl+G back to the IDE.'
        WordWrap = True
      end
      object chkGoTo: TCheckBox
        Left = 16
        Top = 250
        Width = 430
        Height = 17
        Caption = 'Go To (Ctrl+G)'
        Checked = True
        State = cbChecked
        TabOrder = 3
      end
      object lblUnitDialogsHint: TLabel
        Left = 35
        Top = 341
        Width = 405
        Height = 45
        Caption =
          'Replace the IDE'#39's View Unit and Use Unit dialogs with lists of' +
          ' every unit the analysis reached - implicit units and libraries' +
          ' included. Off hands both keys back to the IDE.'
        WordWrap = True
      end
      object chkUnitDialogs: TCheckBox
        Left = 16
        Top = 320
        Width = 430
        Height = 17
        Caption = 'View Unit (Ctrl+F12) and Use Unit (Alt+F11)'
        Checked = True
        State = cbChecked
        TabOrder = 4
      end
    end
    object tsEditing: TTabSheet
      Caption = 'Editing'
      ImageIndex = 1
      object lblRenameHint: TLabel
        Left = 35
        Top = 41
        Width = 405
        Height = 30
        Caption =
          'Renames a symbol across the project and lists every changed line' +
          ' in its own Messages tab. Off hides the command entirely.'
        WordWrap = True
      end
      object lblClassCompleteHint: TLabel
        Left = 35
        Top = 111
        Width = 405
        Height = 30
        Caption =
          'Implements what is declared, and first mirrors a changed signatu' +
          're onto the routine'#39's other half. Off leaves the key to the IDE.'
        WordWrap = True
      end
      object lblClassCompleteOrder: TLabel
        Left = 35
        Top = 149
        Width = 108
        Height = 15
        Caption = 'New method bodies go'
        FocusControl = cbxClassCompleteOrder
      end
      object cbxClassCompleteOrder: TComboBox
        Left = 170
        Top = 145
        Width = 270
        Height = 23
        Style = csDropDownList
        TabOrder = 2
        Items.Strings = (
          'In alphabetical order (like Delphi)'
          'In declaration order')
      end
      object lblBlockCompletionHint: TLabel
        Left = 35
        Top = 211
        Width = 405
        Height = 30
        Caption =
          'Inserts the missing end;/until ; on the next line when Enter is ' +
          'pressed right after an unclosed block opener.'
        WordWrap = True
      end
      object chkRename: TCheckBox
        Left = 16
        Top = 20
        Width = 430
        Height = 17
        Caption = 'Rename (Ctrl+Shift+E)'
        Checked = True
        State = cbChecked
        TabOrder = 0
      end
      object chkClassComplete: TCheckBox
        Left = 16
        Top = 90
        Width = 430
        Height = 17
        Caption = 'Complete Class At Cursor (Ctrl+Shift+C)'
        Checked = True
        State = cbChecked
        TabOrder = 1
        OnClick = chkClassCompleteClick
      end
      object chkBlockCompletion: TCheckBox
        Left = 16
        Top = 190
        Width = 430
        Height = 17
        Caption = 'Block completion (Enter after begin/try/case/repeat)'
        Checked = True
        State = cbChecked
        TabOrder = 3
      end
    end
    object tsDiagnostics: TTabSheet
      Caption = 'Diagnostics'
      ImageIndex = 2
      object lblLoggingHint: TLabel
        Left = 35
        Top = 41
        Width = 405
        Height = 30
        Caption =
          'Writes pastree-lsp.log next to the project file - the handshake,' +
          ' the analysis timings and every failed navigation. Off writes no' +
          'thing.'
        WordWrap = True
      end
      object lblAdvancedLoggingHint: TLabel
        Left = 35
        Top = 111
        Width = 405
        Height = 30
        Caption =
          'Adds every search path, define, namespace and unit alias to the ' +
          'log. Off keeps the one-line summary with the counts.'
        WordWrap = True
      end
      object chkLogging: TCheckBox
        Left = 16
        Top = 20
        Width = 430
        Height = 17
        Caption = 'Enable logging'
        Checked = True
        State = cbChecked
        TabOrder = 0
        OnClick = chkLoggingClick
      end
      object chkAdvancedLogging: TCheckBox
        Left = 16
        Top = 90
        Width = 430
        Height = 17
        Caption = 'Advanced logging (paths, defines, namespaces, aliases)'
        TabOrder = 1
      end
      object lblClearLogOnOpenHint: TLabel
        Left = 35
        Top = 181
        Width = 405
        Height = 30
        Caption =
          'Empties the project'#39's log when the project is opened, so the ' +
          'log is this session'#39's alone. Off appends every run, separated ' +
          'by a line of dashes.'
        WordWrap = True
      end
      object chkClearLogOnOpen: TCheckBox
        Left = 16
        Top = 160
        Width = 430
        Height = 17
        Caption = 'Clear log when opening a project'
        Checked = True
        State = cbChecked
        TabOrder = 2
      end
    end
    object tsHighlighting: TTabSheet
      Caption = 'Highlighting'
      ImageIndex = 3
      object lblTypeColor: TLabel
        Left = 26
        Top = 46
        Width = 32
        Height = 15
        Caption = 'Color:'
      end
      object lblPreview: TLabel
        Left = 26
        Top = 98
        Width = 44
        Height = 15
        Caption = 'Preview:'
      end
      object pbxPreview: TPaintBox
        Left = 26
        Top = 118
        Width = 405
        Height = 40
        OnPaint = pbxPreviewPaint
      end
      object chkHighlightTypes: TCheckBox
        Left = 16
        Top = 20
        Width = 430
        Height = 17
        Caption = 'Color type names in the editor'
        Checked = True
        State = cbChecked
        TabOrder = 0
        OnClick = chkHighlightTypesClick
      end
      object cbxTypeColor: TColorBox
        Left = 64
        Top = 43
        Width = 200
        Height = 22
        Style = [cbStandardColors, cbExtendedColors, cbCustomColor, cbPrettyNames]
        TabOrder = 1
        OnChange = TypeStyleChanged
      end
      object chkTypeBold: TCheckBox
        Left = 64
        Top = 71
        Width = 51
        Height = 17
        Caption = 'Bold'
        TabOrder = 2
        OnClick = TypeStyleChanged
      end
      object chkTypeItalic: TCheckBox
        Left = 121
        Top = 71
        Width = 54
        Height = 17
        Caption = 'Italic'
        TabOrder = 3
        OnClick = TypeStyleChanged
      end
      object chkTypeUnderline: TCheckBox
        Left = 183
        Top = 71
        Width = 81
        Height = 17
        Caption = 'Underline'
        TabOrder = 4
        OnClick = TypeStyleChanged
      end
      object lblErrorSquiggles: TLabel
        Left = 16
        Top = 190
        Width = 128
        Height = 15
        Caption = 'Error underlines drawn by'
        FocusControl = cbxErrorSquiggles
      end
      object cbxErrorSquiggles: TComboBox
        Left = 170
        Top = 186
        Width = 270
        Height = 23
        Style = csDropDownList
        TabOrder = 5
        Items.Strings = (
          'RAD Studio (Error Insight)'
          'PasTree (experimental)')
      end
      object lblErrorSquigglesHint: TLabel
        Left = 35
        Top = 216
        Width = 405
        Height = 60
        Caption =
          'PasTree draws the analysis'#39's errors and warnings itself and sets' +
          ' the IDE'#39's Error Insight level to None, so they are not drawn tw' +
          'ice. Switching back restores the level it replaced. The IDE may ' +
          'need a restart to pick up its own level.'
        WordWrap = True
      end
    end
  end
  object btnOK: TButton
    Left = 312
    Top = 564
    Width = 85
    Height = 27
    Caption = 'OK'
    Default = True
    ModalResult = 1
    TabOrder = 2
  end
  object btnCancel: TButton
    Left = 403
    Top = 564
    Width = 85
    Height = 27
    Cancel = True
    Caption = 'Cancel'
    ModalResult = 2
    TabOrder = 3
  end
end
