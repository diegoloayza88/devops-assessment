from fastapi import FastAPI
from pydantic import BaseModel
from transformers import AutoTokenizer, AutoModelForCausalLM
import torch, uvicorn, os

app = FastAPI()
MODEL_NAME = os.getenv("MODEL_NAME", "HuggingFaceTB/SmolLM2-135M-Instruct")

print(f"Loading {MODEL_NAME}...")
tokenizer = AutoTokenizer.from_pretrained(MODEL_NAME)
model = AutoModelForCausalLM.from_pretrained(MODEL_NAME, torch_dtype=torch.float32)
model.eval()
print("Model ready.")

class CompletionRequest(BaseModel):
    prompt: str
    max_tokens: int = 200
    temperature: float = 0.7

@app.get("/health")
def health():
    return {"status": "ok"}

@app.post("/v1/completions")
def completions(req: CompletionRequest):
    inputs = tokenizer(req.prompt, return_tensors="pt")
    with torch.no_grad():
        outputs = model.generate(
            **inputs,
            max_new_tokens=req.max_tokens,
            temperature=req.temperature,
            do_sample=req.temperature > 0,
            pad_token_id=tokenizer.eos_token_id,
        )
    generated = outputs[0][inputs["input_ids"].shape[1]:]
    text = tokenizer.decode(generated, skip_special_tokens=True)
    return {
        "choices": [{"text": text, "finish_reason": "stop"}],
        "model": MODEL_NAME,
    }

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)

