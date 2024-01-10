import QtCore
import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Basic
import QtQuick.Layouts

Item {
    id: root
    property string title: ""
    property Item contentItem: null
    property Item advancedSettings: null
    property var openFolderDialog
    signal restoreDefaultsClicked

    onContentItemChanged: function() {
        if (contentItem) {
            contentItem.parent = contentInner;
            contentItem.anchors.left = contentInner.left;
            contentItem.anchors.right = contentInner.right;
        }
    }

    onAdvancedSettingsChanged: function() {
        if (advancedSettings) {
            advancedSettings.parent = advancedInner;
            advancedSettings.anchors.left = advancedInner.left;
            advancedSettings.anchors.right = advancedInner.right;
        }
    }

    ScrollView {
        width: parent.width
        height: parent.height
        padding: 15
        rightPadding: 20
        contentWidth: availableWidth
        contentHeight: innerColumn.height
        ScrollBar.vertical.policy: ScrollBar.AlwaysOn

        Theme {
            id: theme
        }

        ColumnLayout {
            id: innerColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: 15
            spacing: 10
            Column {
                id: contentInner
                Layout.fillWidth: true
            }

            Column {
                id: advancedInner
                visible: false
                Layout.fillWidth: true
            }

            Item {
                Layout.fillWidth: true
                height: restoreDefaultsButton.height
                MyButton {
                    id: restoreDefaultsButton
                    anchors.left: parent.left
                    width: implicitWidth
                    text: qsTr("Restore Defaults")
                    font.pixelSize: theme.fontSizeLarge
                    Accessible.role: Accessible.Button
                    Accessible.name: text
                    Accessible.description: qsTr("Restores the settings dialog to a default state")
                    onClicked: {
                        root.restoreDefaultsClicked();
                    }
                }
                MyButton {
                    id: advancedSettingsButton
                    anchors.right: parent.right
                    visible: root.advancedSettings
                    width: implicitWidth
                    text: !advancedInner.visible ? qsTr("Advanced Settings") : qsTr("Hide Advanced Settings")
                    font.pixelSize: theme.fontSizeLarge
                    Accessible.role: Accessible.Button
                    Accessible.name: text
                    Accessible.description: qsTr("Shows/hides the advanced settings")
                    onClicked: {
                        advancedInner.visible = !advancedInner.visible;
                    }
                }
            }
        }
    }
}
