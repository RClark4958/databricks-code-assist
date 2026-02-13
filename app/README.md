# Intermountain Application

This is a React frontend with FastAPI backend application branded for Intermountain.

## Project Structure

```
app/
├── backend/           # FastAPI backend
│   ├── main.py        # Main FastAPI application
│   └── requirements.txt
└── frontend/          # React frontend
    ├── public/        # Static files
    └── src/           # React source code
        ├── assets/    # Images and other assets
        ├── components/# Reusable components
        ├── pages/     # Page components
        └── App.js     # Main React component
```

## Getting Started

### Backend Setup

1. Navigate to the backend directory:
   ```
   cd app/backend
   ```

2. Create a virtual environment:
   ```
   python -m venv venv
   source venv/bin/activate  # On Windows: venv\Scripts\activate
   ```

3. Install dependencies:
   ```
   pip install -r requirements.txt
   ```

4. Run the FastAPI server:
   ```
   python main.py
   ```

The API will be available at http://localhost:8000

### Frontend Setup

1. Navigate to the frontend directory:
   ```
   cd app/frontend
   ```

2. Install dependencies:
   ```
   npm install
   ```

3. Start the development server:
   ```
   npm start
   ```

The React app will be available at http://localhost:3000

## Building for Production

1. Build the React frontend:
   ```
   cd app/frontend
   npm run build
   ```

2. The FastAPI server is configured to serve the built React app from the `frontend/build` directory.

## API Endpoints

- `GET /api/health`: Health check endpoint that returns the API status and version.
