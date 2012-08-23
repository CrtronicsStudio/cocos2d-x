require "helper"


Action_Table =
{
    "ACTION_MANUAL_LAYER",
    "ACTION_MOVE_LAYER",
    "ACTION_SCALE_LAYER",
    "ACTION_ROTATE_LAYER",
    "ACTION_SKEW_LAYER",
    "ACTION_SKEWROTATE_LAYER",
    "ACTION_JUMP_LAYER",
    "ACTION_CARDINALSPLINE_LAYER",
    "ACTION_CATMULLROM_LAYER",
    "ACTION_BEZIER_LAYER",
    "ACTION_BLINK_LAYER",
    "ACTION_FADE_LAYER",
    "ACTION_TINT_LAYER",
    "ACTION_ANIMATE_LAYER",
    "ACTION_SEQUENCE_LAYER",
    "ACTION_SEQUENCE2_LAYER",
    "ACTION_SPAWN_LAYER",
    "ACTION_REVERSE",
    "ACTION_DELAYTIME_LAYER",
    "ACTION_REPEAT_LAYER",
    "ACTION_REPEATEFOREVER_LAYER",
    "ACTION_ROTATETOREPEATE_LAYER",
    "ACTION_ROTATEJERK_LAYER",
    "ACTION_CALLFUNC_LAYER",
--   problem: no corresponding function in CCLuaEngine yet
--    "ACTION_CALLFUNCND_LAYER",
    "ACTION_REVERSESEQUENCE_LAYER",
    "ACTION_REVERSESEQUENCE2_LAYER",
    "ACTION_ORBIT_LAYER",
    "ACTION_FOLLOW_LAYER",
    "ACTION_TARGETED_LAYER",
--   problem: schedule feature hasn't implement on lua yet
--    "PAUSERESUMEACTIONS_LAYER",
--    "ACTION_ISSUE1305_LAYER",
    "ACTION_ISSUE1305_2_LAYER",
    "ACTION_ISSUE1288_LAYER",
    "ACTION_ISSUE1288_2_LAYER",
    "ACTION_ISSUE1327_LAYER",
    "ACTION_LAYER_COUNT",
}

Action_Table = CreateEnumTable(Action_Table)