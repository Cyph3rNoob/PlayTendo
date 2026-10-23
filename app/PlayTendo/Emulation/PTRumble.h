// PTRumble.h — vibrations des moteurs (libretro, PS2, GameCube/Wii) vers la manette de l'app (GamepadManager).
#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Force des deux moteurs (gros et petit, de 0 à 1) de la manette `port` (0 : joueur 1). Appelable de n'importe quel fil.
void PTRumbleSet(unsigned int port, float strong, float weak);
/// Reçoit ces vibrations ; nil : plus personne (fin de partie).
void PTRumbleSetHandler(void (^_Nullable handler)(unsigned int port, float strong, float weak));

NS_ASSUME_NONNULL_END
