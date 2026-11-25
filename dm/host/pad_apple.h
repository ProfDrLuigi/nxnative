// A physical controller's face buttons as Switch buttons, shared by the Mac front end (front_mac.m) and the iOS gamepad (DmGamepad.m). GameController names most pads' face
// buttons by position, as on an Xbox pad (buttonA bottom, buttonB right, buttonX left, buttonY top), but a Nintendo pad's by their printed labels (buttonA is the right
// button, marked A): a Switch Pro Controller (or a pad that presents itself as one) and Joy-Con (productCategory "Nintendo Switch Joy-Con (L)", "(R)", "(L/R)").
// The Switch's layout is right A, bottom B, top X, left Y, so a Nintendo pad maps name for name and any other pad by position. Checked with a Pro Controller on the Mac
// and on iOS (PR #650). Open: a single Joy-Con held sideways is matched too and has not been tried; if GameController keeps its labels there instead of turning them
// with the controller, its face buttons come out a quarter turn off.
#pragma once
#import <GameController/GameController.h>
#include <stdint.h>
#include <stdlib.h>
#include <strings.h>
#include "dm_input.h"

static inline int dm_pad_labelled(GCController *c) {
    NSString *k = c.productCategory;
    return [k isEqualToString:@"Switch Pro Controller"] || [k containsString:@"Joy-Con"];
}
// DM_BTN_A / B / X / Y of the pad's pressed face buttons. by_label: 1 reads GameController's names as printed letters, 0 as Xbox positions, -1 by the pad (dm_pad_labelled)
static inline uint64_t dm_pad_face_as(GCExtendedGamepad *g, int by_label) {
    GCControllerButtonInput *a = g.buttonA, *b = g.buttonB, *x = g.buttonX, *y = g.buttonY;
    if (by_label < 0) by_label = dm_pad_labelled(g.controller) || dm_pad_labels_mode();
    if (!by_label) { GCControllerButtonInput *t = a; a = b; b = t; t = x; x = y; y = t; }   // by position: right A, bottom B, top X, left Y
    return (a.isPressed ? DM_BTN_A : 0) | (b.isPressed ? DM_BTN_B : 0) | (x.isPressed ? DM_BTN_X : 0) | (y.isPressed ? DM_BTN_Y : 0);
}
static inline uint64_t dm_pad_face(GCExtendedGamepad *g) { return dm_pad_face_as(g, -1); }

// All NpadButton bits of an extended gamepad (face + shoulders, triggers, menu/options, stick clicks, dpad), with DM_PAD_LAYOUT and DM_PAD_MAP applied.
static inline uint64_t dm_pad_buttons(GCExtendedGamepad *g) {
    uint64_t m = dm_pad_face(g);
    #define K(btn, bit) if (btn.isPressed) m |= (bit)
    K(g.leftShoulder, DM_BTN_L); K(g.rightShoulder, DM_BTN_R); K(g.leftTrigger, DM_BTN_ZL); K(g.rightTrigger, DM_BTN_ZR);
    K(g.buttonMenu, DM_BTN_PLUS); K(g.buttonOptions, DM_BTN_MINUS); K(g.leftThumbstickButton, DM_BTN_LS); K(g.rightThumbstickButton, DM_BTN_RS);   // nil on pads without them: not pressed
    K(g.dpad.left, DM_BTN_LEFT); K(g.dpad.up, DM_BTN_UP); K(g.dpad.right, DM_BTN_RIGHT); K(g.dpad.down, DM_BTN_DOWN);
    #undef K
    return dm_pad_remap(m);
}
