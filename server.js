const express = require("express");
const app = express();
const PORT = 3000;

app.use(express.static("public"));
app.use(express.json());

/*
  🔒 REAL API GOES HERE LATER
  NEVER PUT API KEYS IN FRONTEND
*/

let players = [
  { id:1, name:"HighRoller", wager:9800, avatar:"https://i.pravatar.cc/150?img=1" },
  { id:2, name:"WinovoKing", wager:7600, avatar:"https://i.pravatar.cc/150?img=2" },
  { id:3, name:"SargeFan", wager:6400, avatar:"https://i.pravatar.cc/150?img=3" },
  { id:4, name:"LuckySpin", wager:5100, avatar:"https://i.pravatar.cc/150?img=4" },
  { id:5, name:"RedRoom", wager:4200, avatar:"https://i.pravatar.cc/150?img=5" },
  { id:6, name:"CasualJoe", wager:2600, avatar:"https://i.pravatar.cc/150?img=6" }
];

const ADMIN_PASSWORD = "sargeisgay123";

/* LEADERBOARD */
app.get("/api/leaderboard", (req,res)=>{
  res.json(players.sort((a,b)=>b.wager-a.wager));
});

/* ADMIN RESET */
app.post("/api/admin/reset",(req,res)=>{
  if(req.body.password !== ADMIN_PASSWORD)
    return res.status(401).json({error:"Unauthorized"});

  players.forEach(p=>p.wager=0);
  res.json({success:true});
});

app.listen(PORT, ()=>console.log(`✅ http://localhost:${PORT}`));
