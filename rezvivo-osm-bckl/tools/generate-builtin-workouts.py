"""Build the original REZVIVO starter library. No external workout sources."""
from pathlib import Path
import json
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
def ramp(tag, seconds, low, high):
    return tag, dict(Duration=seconds, PowerLow=low, PowerHigh=high)
def steady(seconds, power):
    return 'SteadyState', dict(Duration=seconds, Power=power)
def intervals(repeats, work, rest, on, off, **extra):
    return 'IntervalsT', dict(Repeat=repeats, OnDuration=work, OffDuration=rest, OnPower=on, OffPower=off, **extra)
warm=lambda seconds=300: ramp('Warmup',seconds,.45,.70)
cool=lambda: ramp('Cooldown',300,.60,.40)

PLANS = [
 ('Recovery','recovery-25','Easy spin · 25 min',25,'5 min gradual start, 15 min at 55%, 5 min gradual finish.',[ramp('Warmup',300,.4,.55),steady(900,.55),ramp('Cooldown',300,.55,.35)]),
 ('Endurance','endurance-45','Steady ride · 45 min',45,'8 min warm-up, 32 min at 68%, 5 min cool-down.',[warm(480),steady(1920,.68),cool()]),
 ('Endurance','endurance-60','Long steady ride · 60 min',60,'8 min warm-up, 47 min at 68%, 5 min cool-down.',[warm(480),steady(2820,.68),cool()]),
 ('Tempo','tempo-40','Tempo steps · 40 min',40,'8 min warm-up, 3 × (6 min at 82% / 2 min at 55%), 3 min easy, 5 min cool-down.',[warm(480),intervals(3,360,120,.82,.55),steady(180,.60),cool()]),
 ('Intervals','intervals-30','Six repeats · 30 min',30,'5 min warm-up, 6 × (2 min at 100% / 1 min at 50%), 2 min easy, 5 min cool-down.',[warm(),intervals(6,120,60,1,.50),steady(120,.60),cool()]),
 ('Intervals','intervals-38','Five long repeats · 38 min',38,'8 min warm-up, 5 × (3 min at 110% / 2 min at 50%), 5 min cool-down.',[warm(480),intervals(5,180,120,1.10,.50),cool()]),
 ('Cadence','cadence-35','Cadence changes · 35 min',35,'5 min warm-up, 5 × (3 min at 70% and 95 rpm / 2 min at 55% and 80 rpm), 5 min cool-down.',[warm(),intervals(5,180,120,.70,.55,Cadence=95,CadenceResting=80),cool()]),
]
RU = [
 ('Лёгкое вращение · 25 мин','5 мин плавного старта, 15 мин на 55%, 5 мин плавного завершения.'),
 ('Ровная езда · 45 мин','8 мин разминки, 32 мин на 68%, 5 мин заминки.'),
 ('Длинная ровная езда · 60 мин','8 мин разминки, 47 мин на 68%, 5 мин заминки.'),
 ('Темповые ступени · 40 мин','8 мин разминки, 3 × (6 мин на 82% / 2 мин на 55%), 3 мин легко, 5 мин заминки.'),
 ('Шесть повторов · 30 мин','5 мин разминки, 6 × (2 мин на 100% / 1 мин на 50%), 2 мин легко, 5 мин заминки.'),
 ('Пять длинных повторов · 38 мин','8 мин разминки, 5 × (3 мин на 110% / 2 мин на 50%), 5 мин заминки.'),
 ('Смена каденса · 35 мин','5 мин разминки, 5 × (3 мин на 70% и 95 об/мин / 2 мин на 55% и 80 об/мин), 5 мин заминки.'),
]

def main():
    translations={}
    for (category, slug, name, minutes, description, segments),ru in zip(PLANS,RU):
        root=ET.Element('workout_file')
        for key,value in [('author','REZVIVO'),('name',name),('description',description),('sportType','bike')]:
            ET.SubElement(root,key).text=value
        workout=ET.SubElement(root,'workout')
        duration=0
        for tag,attrs in segments:
            ET.SubElement(workout,tag,{k:str(v) for k,v in attrs.items()})
            duration+=attrs.get('Duration',attrs.get('Repeat',0)*(attrs.get('OnDuration',0)+attrs.get('OffDuration',0)))
        assert duration==minutes*60,(slug,duration)
        target=ROOT/'data/workouts/rezvivo'/category/(slug+'.zwo')
        target.parent.mkdir(parents=True,exist_ok=True)
        ET.indent(root)
        ET.ElementTree(root).write(target,encoding='utf-8',xml_declaration=True)
        translations[name]=ru[0];translations[description]=ru[1]
    for lang,values in [('ru',translations),('en',{k:k for k in translations})]:
        path=ROOT/f'data/translations/{lang}.json'
        data=json.loads(path.read_text(encoding='utf-8-sig'));data.update(values)
        path.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(f'Generated {len(PLANS)} original REZVIVO workouts; durations verified')
if __name__=='__main__':main()
