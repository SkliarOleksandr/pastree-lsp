object PasTreeUnitPickerForm: TPasTreeUnitPickerForm
  Left = 0
  Top = 0
  Caption = 'View Unit'
  ClientHeight = 450
  ClientWidth = 480
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
    Top = 431
    Width = 480
    Height = 19
    Panels = <
      item
        Text = 'units'
        Width = 300
      end
      item
        Text = 'project'
        Width = 500
      end>
  end
  object pnlButtons: TPanel
    Left = 0
    Top = 395
    Width = 480
    Height = 36
    Align = alBottom
    BevelOuter = bvNone
    ShowCaption = False
    TabOrder = 2
    DesignSize = (
      480
      36)
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
      Left = 120
      Top = 9
      Width = 180
      Height = 21
      Caption = 'All files in project group'
      TabOrder = 5
      OnClick = chkGroupClick
    end
    object rbInterface: TRadioButton
      Left = 120
      Top = 9
      Width = 76
      Height = 21
      Caption = 'Interface'
      TabOrder = 1
    end
    object rbImplementation: TRadioButton
      Left = 200
      Top = 9
      Width = 108
      Height = 21
      Caption = 'Implementation'
      Checked = True
      TabOrder = 2
      TabStop = True
    end
    object btnOK: TButton
      Left = 316
      Top = 3
      Width = 78
      Height = 27
      Anchors = [akTop, akRight]
      Caption = 'OK'
      Default = True
      TabOrder = 3
      OnClick = btnOKClick
    end
    object btnCancel: TButton
      Left = 398
      Top = 3
      Width = 78
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
    Width = 472
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
