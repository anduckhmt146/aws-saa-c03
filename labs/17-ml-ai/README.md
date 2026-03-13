# Lab 17 - ML/AI Services

> Exam weight: **3-5%** of SAA-C03 questions — know the basics

## What This Lab Creates

- SageMaker Notebook Instance (Jupyter)
- SageMaker Model + Endpoint Config + Endpoint (real-time inference)
- Rekognition Custom Labels project
- Lex V2 Bot
- Transcribe custom vocabulary
- IAM roles for each AI service
- S3 buckets (data, models, output)

## Run

```bash
terraform init
terraform apply   # SageMaker endpoint takes ~5 min
terraform destroy # Deletes endpoint/notebook — no idle charges
```

---

## Key Concepts

### AI/ML Quick Reference (MEMORIZE)

| Keyword | Service |
|---------|---------|
| Images/Videos → detect objects, faces, labels | **Rekognition** |
| Text analysis → sentiment, entities, language | **Comprehend** |
| Speech-to-text → transcribe audio | **Transcribe** |
| Text-to-speech → generate audio | **Polly** |
| Language translation | **Translate** |
| Chatbots (Alexa tech) | **Lex** |
| Time-series forecasting | **Forecast** |
| Personalized recommendations | **Personalize** |
| Custom ML models (build/train/deploy) | **SageMaker** |
| Search (semantic) | **Kendra** |
| Code suggestions (ML) | **CodeWhisperer / CodeGuru** |

### SageMaker

Full ML lifecycle platform:

```
Data prep (Data Wrangler)
  ↓
Experiment (Notebook/Studio)
  ↓
Train (Training Job — EC2 + S3)
  ↓
Evaluate (metrics, confusion matrix)
  ↓
Deploy (Endpoint — real-time or batch)
  ↓
Monitor (Model Monitor — data drift)
```

**Deployment types**:
| Type | Use Case |
|------|---------|
| Real-time Endpoint | Low-latency predictions |
| Batch Transform | Large dataset, async |
| Serverless Inference | Infrequent traffic, no cold-start cost |
| Async Inference | Large payloads, long processing |

**Exam Tips**:
- "Build custom ML model" → SageMaker
- "Jupyter notebooks on AWS" → SageMaker Notebook / Studio
- "Auto tune hyperparameters" → SageMaker Automatic Model Tuning
- "MLOps pipeline" → SageMaker Pipelines

### Rekognition

- **No ML expertise needed** — call API with image/video
- Detects: objects, scenes, faces, text, celebrities, unsafe content
- **Face Search**: compare faces against a collection
- **Video analysis**: async job (stored in S3)

```python
# Example API call
client.detect_labels(Image={'S3Object': {'Bucket': 'bucket', 'Name': 'photo.jpg'}})
```

**Exam Tip**: "Image moderation" or "facial recognition" → Rekognition

### Comprehend

- NLP (Natural Language Processing)
- Capabilities: sentiment, entities, key phrases, language detection, syntax
- **Comprehend Medical**: extract medical info from text (diagnoses, medications)
- **Custom Classification**: train on your own categories

**Exam Tip**: "Analyze customer feedback" or "extract entities from text" → Comprehend

### Transcribe

- Speech → Text (ASR = Automatic Speech Recognition)
- **Speaker diarization**: identify who said what
- **Custom vocabulary**: improve accuracy for domain terms
- **PII redaction**: remove sensitive info from transcript
- Input: S3 (audio files) or streaming

**Exam Tip**: "Transcribe call center recordings" → Transcribe

### Polly

- Text → Speech
- **Standard voices**: concatenated audio
- **Neural voices**: more natural (NTTS)
- **SSML support**: control pace, pitch, pronunciation
- Output: MP3, OGG, PCM, Speech Marks

### Translate

- **Neural Machine Translation**
- 75+ languages
- **Custom terminology**: domain-specific translations
- Use case: real-time content translation

### Lex

- **Conversational AI** (same engine as Alexa)
- **Intents**: what user wants to do
- **Slots**: parameters (date, location, amount)
- **Fulfillment**: Lambda to execute the intent
- **Channels**: web, mobile, Slack, Twilio, Connect

**Exam Tip**: "Build chatbot" or "IVR/voice interface" → Lex + Connect

### Amazon Connect

- Cloud **contact center** (call center)
- Integrates with Lex (chatbot), Lambda (logic), S3 (recordings)
- **Exam Tip**: "Cloud contact center" → Connect

### Forecast

- Time-series forecasting using ML
- Input: historical data in S3
- Auto-selects best algorithm (DeepAR, ETS, ARIMA, Prophet)
- Use case: inventory, demand, capacity planning

### Personalize

- Real-time **recommendations** (same tech as Amazon.com)
- Input: users, items, interactions → training → recommendations
- Use case: e-commerce ("customers also bought"), streaming ("you might like")

### Kendra

- **Intelligent search** powered by ML
- Sources: S3, SharePoint, Confluence, Salesforce, Websites
- Understands natural language questions
- **Exam Tip**: "Semantic search across documents" → Kendra

### Textract

- Extract text and structured data from documents
- Beyond OCR: understands forms, tables, checkboxes
- Use case: process invoices, forms, tax documents
- **Exam Tip**: "Extract data from scanned documents" → Textract
