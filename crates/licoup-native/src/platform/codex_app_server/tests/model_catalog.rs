use super::super::model_catalog::project_model_list_response;
use serde_json::json;

#[test]
fn projects_visible_native_models_without_collapsing_duplicate_labels() {
    let result = project_model_list_response(&json!({
        "data": [
            {"model":"first","displayName":"Same","hidden":false,"isDefault":true,
             "defaultReasoningEffort":"medium",
             "supportedReasoningEfforts":[{"reasoningEffort":"low"},{"reasoningEffort":"medium"}]},
            {"model":"second","displayName":"Same","hidden":false,"isDefault":false,
             "supportedReasoningEfforts":[{"reasoningEffort":"high"}]},
            {"model":"hidden","displayName":"Hidden","hidden":true}
        ]
    }))
    .unwrap();
    assert_eq!(result["defaultModel"], "first");
    assert_eq!(result["models"].as_array().unwrap().len(), 2);
    assert_eq!(result["models"][0]["displayName"], "Same");
    assert_eq!(result["models"][0]["defaultReasoningEffort"], "medium");
    assert_eq!(result["models"][1]["displayName"], "Same");
    assert!(result["models"][1].get("defaultReasoningEffort").is_none());
}
