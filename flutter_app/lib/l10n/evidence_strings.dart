// Presentation-layer strings for the evidence-linked grading extension
// (schema_version 1.0).
//
// NOT generated from Figma: these belong to the screening flow layer
// (like the existing hardcoded flow literals), hand-maintained here.
// Clinical logic lives in the backend policy
// (`src/services/grading_policy.py`); this map only turns payload-provided
// criterion ids and reason codes into display text. Unknown ids fall back
// to English neutral text — never a fabricated clinical claim.
import 'package:flutter/widgets.dart';

import 'lang_scope.dart';

class EvidenceStrings {
  EvidenceStrings._();

  static const Map<String, String> _en = {
    'evidence_title': 'Lesion evidence',
    'candidate_ma': 'Suspected microaneurysm (candidate)',
    'candidate_exudate': 'Suspected exudate (candidate)',
    'candidate_unknown': 'Lesion candidate (unclassified type)',
    'status_detected': 'Detected by classical CV — not a confirmed lesion',
    'evidence_notes_label': 'What this is',
    'criteria_title': 'Why this grade — criteria evidence',
    'criterion_status_satisfied': 'Evidence present',
    'criterion_status_indeterminate': 'Indeterminate',
    'criterion_status_not_evaluated': 'Not evaluated (no detector)',
    'criterion_show_markers': 'Show supporting markers',
    'disagreement_conflict':
        'Model and image evidence disagree — doctor review required',
    'disagreement_adjacent':
        'Model and evidence differ by one level — advisory',
    'disagreement_match': 'Model and evidence agree',
    'disagreement_incomplete':
        'Evidence incomplete — no conflict can be derived',
    'disagreement_not_asserted':
        'No candidates detected — absence is not proof of absence',
    'disagreement_model_unavailable':
        'Model result unavailable — review required',
    'policy_label': 'Criteria policy',
    'tap_hint': 'Tap a marker to inspect its evidence',
    'upper_bound_note':
        'Upper severity levels cannot be excluded: this policy cannot see '
        'venous beading or neovascularisation.',
    'icdrss.ma_present': 'Microaneurysm presence (ICDRS level 1+)',
    'icdrss.exudate_present': 'Exudate presence (ICDRS level 2+)',
    'icdrss.fovea_involvement': 'Lesion near fovea — macular-zone rule',
    'icdrss.venous_beading': 'Venous beading (ICDRS level 3) — not implemented',
    'icdrss.neovascularization':
        'Neovascularisation (ICDRS level 4) — not implemented',
    'capture_empty_file':
        'That photo could not be read (empty file). Please try again.',
    'capture_open_failed':
        'That photo could not be opened. Pick it again or use the camera.',
    'camera_unavailable':
        'Camera unavailable. Check camera permission, or upload a photo instead.',
    'sample_healthy': 'Sample: healthy retina',
    'sample_blurry': 'Sample: blurry capture',
    'sample_severe': 'Sample: severe DR',
  };

  static const Map<String, String> _hi = {
    'evidence_title': 'घाव के सबूत',
    'candidate_ma': 'संभावित माइक्रोएन्यूरिज़्म (उम्मीदवार)',
    'candidate_exudate': 'संभावित एक्सुडेट (उम्मीदवार)',
    'candidate_unknown': 'घाव का उम्मीदवार (अवर्गीकृत)',
    'status_detected': 'क्लासिकल CV द्वारा मिला — पुष्ट घाव नहीं',
    'evidence_notes_label': 'यह क्या है',
    'criteria_title': 'यह ग्रेड क्यों — पैमाने के सबूत',
    'criterion_status_satisfied': 'सबूत मौजूद',
    'criterion_status_indeterminate': 'अनिश्चित',
    'criterion_status_not_evaluated': 'मूल्यांकन नहीं (डिटेक्टर नहीं)',
    'criterion_show_markers': 'संबंधित मार्कर दिखाएं',
    'disagreement_conflict':
        'मॉडल और तस्वीर के सबूत में मतभेद — डॉक्टर समीक्षा आवश्यक',
    'disagreement_adjacent': 'मॉडल और सबूत एक स्तर अलग — सलाह',
    'disagreement_match': 'मॉडल और सबूत सहमत',
    'disagreement_incomplete': 'सबूत अधूरा — मतभेद नहीं बताया जा सकता',
    'disagreement_not_asserted':
        'कोई उम्मीदवार नहीं मिला — न मिलना प्रमाण नहीं',
    'disagreement_model_unavailable': 'मॉडल परिणाम अनुपलब्ध — समीक्षा आवश्यक',
    'policy_label': 'पैमाना नीति',
    'tap_hint': 'सबूत देखने के लिए किसी मार्कर पर टैप करें',
    'upper_bound_note':
        'ऊपरी गंभीरता स्तर बाहर नहीं निकाले जा सकते: यह नीति वेनस बीडिंग या '
        'नियोवैस्कुलराइज़ेशन नहीं देख सकती।',
    'icdrss.ma_present': 'माइक्रोएन्यूरिज़्म उपस्थिति (ICDRS स्तर 1+)',
    'icdrss.exudate_present': 'एक्सुडेट उपस्थिति (ICDRS स्तर 2+)',
    'icdrss.fovea_involvement': 'फोविया के पास घाव — मैकुला-ज़ोन नियम',
    'icdrss.venous_beading': 'वेनस बीडिंग (ICDRS स्तर 3) — लागू नहीं',
    'icdrss.neovascularization':
        'नियोवैस्कुलराइज़ेशन (ICDRS स्तर 4) — लागू नहीं',
    'capture_empty_file':
        'वह फोटो पढ़ी नहीं जा सकी (खाली फ़ाइल)। फिर से कोशिश करें।',
    'capture_open_failed':
        'वह फोटो नहीं खुली। दोबारा चुनें या कैमरा इस्तेमाल करें।',
    'camera_unavailable':
        'कैमरा उपलब्ध नहीं। कैमरा अनुमति जांचें, या फोटो अपलोड करें।',
    'sample_healthy': 'नमूना: स्वस्थ रेटिना',
    'sample_blurry': 'नमूना: धुंधली कैप्चर',
    'sample_severe': 'नमूना: गंभीर डीआर',
  };

  /// Languages with partial coverage fall back to English — documented, never
  /// a fabricated translation.
  static const Map<String, Map<String, String>> _byLang = {
    'en': _en,
    'hi': _hi,
  };

  static String t(String key, {String lang = 'en'}) =>
      _byLang[lang]?[key] ?? _en[key] ?? key;
}

/// `context.ev('criteria_title')` — evidence-layer string in the active
/// language, falling back to English, then to the key itself.
extension EvTrExt on BuildContext {
  String ev(String key) =>
      EvidenceStrings.t(key, lang: LangScope.langOf(this).code);
}
