import QtCore
import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Basic
import QtQuick.Dialogs
import QtQuick.Layouts

Dialog {
    id: myDialog
    property alias closeButtonVisible: myCloseButton.visible
    background: Rectangle {
        width: parent.width
        height: parent.height
        color: theme.backgroundDarkest
        border.width: 1
        border.color: theme.dialogBorder
        radius: 10
    }

    MyToolButton {
        id: myCloseButton
        x: 0 + myDialog.width - myDialog.padding - width - 15
        y: 0 - myDialog.padding + 15
        z: 300
        visible: myDialog.closePolicy != Popup.NoAutoClose
        width: 30
        height: 30
        padding: 0
        source: "qrc:/gpt4all/icons/close.svg"
        fillMode: Image.PreserveAspectFit
        onClicked: {
            myDialog.close();
        }
    }
}
