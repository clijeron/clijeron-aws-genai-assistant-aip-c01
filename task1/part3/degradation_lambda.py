"""
Part 3 — Graceful Degradation Lambda
====================================

Last resort in the Step Functions chain. Returns a safe, predefined response
when both the primary and fallback models are unavailable, so the customer
always gets a coherent (if limited) answer instead of an error.

------------------------------------------------------------------------------
WHAT CHANGED vs. THE ORIGINAL ASSIGNMENT (blog changelog)
------------------------------------------------------------------------------
P3-6. Unchanged in spirit from the assignment — canned per-use-case responses,
      no model call. Kept verbatim in structure; only added a Content-Type
      header and a couple more use_case entries for completeness. This Lambda
      intentionally has NO Bedrock dependency (that's the point of graceful
      degradation).
------------------------------------------------------------------------------
"""

import json


RESPONSES = {
    "general": "I'm sorry, but I'm currently experiencing technical difficulties. Please try again later or contact customer service for immediate assistance.",
    "product_question": "I apologize, but I can't access product information right now. Please refer to our product documentation or contact customer service at 1-800-555-1234.",
    "account_inquiry": "I'm unable to process account inquiries at the moment. For urgent matters, please call our customer service line at 1-800-555-1234.",
}
DEFAULT_RESPONSE = "I'm sorry, but I'm currently experiencing technical difficulties. Please try again later."


def lambda_handler(event, context):
    use_case = event.get("use_case", "general")
    response_text = RESPONSES.get(use_case, DEFAULT_RESPONSE)
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({
            "model_used": "DEGRADED_SERVICE",
            "response": response_text,
        }),
    }
