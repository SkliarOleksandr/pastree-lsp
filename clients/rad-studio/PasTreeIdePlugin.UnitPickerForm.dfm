object PasTreeUnitPickerForm: TPasTreeUnitPickerForm
  Left = 0
  Top = 0
  Caption = 'View Unit'
  ClientHeight = 561
  ClientWidth = 600
  Color = clBtnFace
  Constraints.MinHeight = 300
  Constraints.MinWidth = 480
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  KeyPreview = True
  Position = poMainFormCenter
  OnClose = FormClose
  OnShow = FormShow
  TextHeight = 15
  object sbStatus: TStatusBar
    Left = 0
    Top = 542
    Width = 600
    Height = 19
    Panels = <
      item
        Text = 'units'
        Width = 380
      end
      item
        Text = 'project'
        Width = 500
      end>
  end
  object pnlButtons: TPanel
    Left = 0
    Top = 506
    Width = 600
    Height = 36
    Align = alBottom
    BevelOuter = bvNone
    ShowCaption = False
    TabOrder = 2
    DesignSize = (
      600
      36)
    object lblSection: TLabel
      Left = 124
      Top = 11
      Width = 39
      Height = 15
      Caption = 'Add to:'
    end
    object chkImplicits: TCheckBox
      Left = 8
      Top = 9
      Width = 104
      Height = 21
      Caption = 'Implicit Units'
      TabOrder = 0
      OnClick = chkImplicitsClick
    end
    object chkGroup: TCheckBox
      Left = 124
      Top = 9
      Width = 180
      Height = 21
      Caption = 'All files in project group'
      TabOrder = 5
      OnClick = chkGroupClick
    end
    object rbInterface: TRadioButton
      Left = 172
      Top = 9
      Width = 76
      Height = 21
      Caption = 'Interface'
      TabOrder = 1
    end
    object rbImplementation: TRadioButton
      Left = 252
      Top = 9
      Width = 112
      Height = 21
      Caption = 'Implementation'
      Checked = True
      TabOrder = 2
      TabStop = True
    end
    object btnOK: TButton
      Left = 390
      Top = 3
      Width = 100
      Height = 27
      Anchors = [akTop, akRight]
      Caption = 'OK'
      Default = True
      TabOrder = 3
      OnClick = btnOKClick
    end
    object btnCancel: TButton
      Left = 496
      Top = 3
      Width = 100
      Height = 27
      Anchors = [akTop, akRight]
      Cancel = True
      Caption = 'Cancel'
      ModalResult = 2
      TabOrder = 4
    end
  end
  object edFilter: TEdit
    AlignWithMargins = True
    Left = 4
    Top = 4
    Width = 592
    Height = 23
    Margins.Left = 4
    Margins.Top = 4
    Margins.Right = 4
    Margins.Bottom = 2
    Align = alTop
    TabOrder = 0
    TextHint = 'Filter'
    OnChange = edFilterChange
    OnKeyDown = edFilterKeyDown
  end
end
